`include "config/interface_params.vh"
`include "config/prediction_params.vh"
`include "config/memory_params.vh"
`timescale 1ns/1ps

/*
 * 文件作用：
 * 1. 本文件实现论文/当前 strict tree verify 之后的 KV commit 搬运器。
 * 2. 当比较器或 verify 逻辑已经选定赢家分支后，它负责把 draft KV region 中属于
 *    winner 路径的 KV，逐层逐 beat 搬运到 committed KV region。
 * 3. 在完整路径里，它位于：
 *    tree_verify_dispatcher / comparator / commit 决策
 *      -> kv_commit_copier
 *      -> request_controller / SRAM
 * 4. 它的职责不是判断谁赢，而是纯粹执行“从 draft 地址读，再写到 committed 地址”：
 *    - 外部给出 depth、slot_indices、slot_positions；
 *    - 模块内部遍历 slot × layer × beat；
 *    - 通过 SRAM 读口读出 draft 数据，再通过写口写入 committed 位置。
 */
module kv_commit_copier #(
    parameter integer ADDR_W = `SRAM_ADDR_W,
    parameter integer DATA_WIDTH = `FP16_TILE_DATA_W,
    parameter integer DATA_BUS_W = `SRAM_WDATA_W,
    parameter integer WINDOW_SIZE = `VERIFY_WINDOW_SIZE,
    parameter integer SLOT_ID_W = `SLOT_ID_W,
    parameter integer MAX_LEVELS = `MAX_PRIVATE_NODES_PER_BRANCH,
    parameter integer N_LAYERS = `TOY_N_LAYERS,
    parameter integer NUM_HEADS = 2,
    parameter integer HEAD_DIM = `TOY_HEAD_DIM,
    parameter integer ELEMS_PER_BEAT = DATA_BUS_W / DATA_WIDTH,
    parameter integer HEAD_BEATS = HEAD_DIM / ELEMS_PER_BEAT,
    parameter integer KV_STRIDE = NUM_HEADS * HEAD_BEATS * 2,
    parameter integer KV_LAYER_STRIDE = 4096,
    parameter [ADDR_W-1:0] KV_COMMITTED_BASE = `KV_COMMITTED_BASE,
    parameter [ADDR_W-1:0] KV_DRAFT_BASE = `KV_DRAFT_BASE_MIN
) (
    input  logic clk,
    input  logic rst_n,

    // 提交请求：
    // depth 表示要复制几个 slot，slot_indices / slot_positions 描述 draft 槽位和其目标 committed 位置。
    input  logic                          start,
    input  logic [2:0]                    depth,
    input  logic [MAX_LEVELS*SLOT_ID_W-1:0] slot_indices,
    input  logic [MAX_LEVELS*16-1:0]      slot_positions,

    // SRAM 读写接口：
    // 读口从 draft region 拉数据，写口写回 committed region。
    output logic                          sram_rd_valid,
    input  logic                          sram_rd_ready,
    output logic [ADDR_W-1:0]             sram_rd_addr,
    input  logic                          sram_resp_valid,
    output logic                          sram_resp_ready,
    input  logic [DATA_BUS_W-1:0]         sram_resp_data,
    output logic                          sram_wr_valid,
    input  logic                          sram_wr_ready,
    output logic [ADDR_W-1:0]             sram_wr_addr,
    output logic [DATA_BUS_W-1:0]         sram_wr_data,

    // 状态输出。
    output logic                          done,
    output logic                          busy
);

    // 状态机：
    // ST_IDLE       : 等待一笔新的 commit copy 请求。
    // ST_READ_BEAT  : 对当前 slot/layer/beat 发起 draft 区读。
    // ST_WRITE_BEAT : 把上一状态读到的数据写入 committed 区。
    // ST_DONE       : 单拍完成态，对外拉高 done。
    localparam [1:0] ST_IDLE       = 2'd0,
                     ST_READ_BEAT  = 2'd1,
                     ST_WRITE_BEAT = 2'd2,
                     ST_DONE       = 2'd3;

    logic [1:0] state, state_next;

    // 内部计数器与锁存输入：
    // slot_cnt        : 当前在处理第几个 slot。
    // lat_depth       : 锁存的总 slot 深度。
    // layer_cnt       : 当前在处理第几层。
    // beat_cnt        : 当前在本层 KV 里的第几个 beat。
    // rd_req_accepted_r : 本轮 READ 状态下，读请求是否已经被下游接受。
    logic [2:0]             slot_cnt;       // current slot index (0..depth-1)
    logic [2:0]             lat_depth;      // latched depth
    logic [MAX_LEVELS*SLOT_ID_W-1:0] lat_slot_indices;
    logic [MAX_LEVELS*16-1:0]        lat_slot_positions;
    logic [7:0]             layer_cnt;
    logic                    rd_req_accepted_r;

    // Beat counter within a single slot copy (0..KV_STRIDE-1)
    localparam integer BEAT_CNT_W = $clog2(KV_STRIDE + 1);
    logic [BEAT_CNT_W-1:0]  beat_cnt;

    // Data buffer for read-then-write
    logic [DATA_BUS_W-1:0]  rd_data_buf;

    // 地址计算中间量。
    logic [SLOT_ID_W-1:0]   cur_slot_id;
    logic [15:0]            cur_position;
    logic [ADDR_W-1:0]      src_addr;
    logic [ADDR_W-1:0]      dst_addr;
    logic [ADDR_W-1:0]      layer_base_offset;

    // 从锁存的 slot 列表中取出当前正在复制的 slot_id 和目标 committed position。
    assign cur_slot_id  = lat_slot_indices[slot_cnt*SLOT_ID_W +: SLOT_ID_W];
    assign cur_position = lat_slot_positions[slot_cnt*16 +: 16];

    // 当前层对应的基础偏移。
    assign layer_base_offset =
        {{(ADDR_W-8){1'b0}}, layer_cnt} * KV_LAYER_STRIDE[ADDR_W-1:0];

    // 源地址：
    // draft 区基址 + 当前层偏移 + 当前 slot 的 KV 段偏移 + 当前 beat 偏移。
    assign src_addr = KV_DRAFT_BASE
                    + layer_base_offset
                    + {{(ADDR_W-SLOT_ID_W-BEAT_CNT_W){1'b0}}, cur_slot_id} * KV_STRIDE[ADDR_W-1:0]
                    + {{(ADDR_W-BEAT_CNT_W){1'b0}}, beat_cnt};

    // 目标地址：
    // committed 区基址 + 当前层偏移 + 当前 committed position 对应的 KV 段偏移 + 当前 beat 偏移。
    assign dst_addr = KV_COMMITTED_BASE
                    + layer_base_offset
                    + {{(ADDR_W-16-BEAT_CNT_W){1'b0}}, cur_position} * KV_STRIDE[ADDR_W-1:0]
                    + {{(ADDR_W-BEAT_CNT_W){1'b0}}, beat_cnt};

    // 状态寄存器更新。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= state_next;
    end

    // 状态转移组合逻辑。
    always @(*) begin : fsm_next
        state_next = state;
        case (state)
            ST_IDLE: begin
                // depth>0 时进入真正复制流程；depth=0 直接给一个 done 脉冲。
                if (start && (depth > 3'd0))
                    state_next = ST_READ_BEAT;
                else if (start)
                    state_next = ST_DONE;
            end

            ST_READ_BEAT: begin
                // 读响应到达后，进入写阶段。
                if (sram_resp_valid && (rd_req_accepted_r || sram_rd_ready))
                    state_next = ST_WRITE_BEAT;
            end

            ST_WRITE_BEAT: begin
                if (sram_wr_ready) begin
                    // 当前 slot 的最后一层最后一个 beat 写完后，整个搬运完成。
                    if ((beat_cnt == KV_STRIDE[BEAT_CNT_W-1:0] - 1) &&
                        (slot_cnt == lat_depth - 3'd1) &&
                        (layer_cnt == N_LAYERS - 1))
                        state_next = ST_DONE;
                    else
                        state_next = ST_READ_BEAT;
                end
            end

            ST_DONE: begin
                state_next = ST_IDLE;
            end

            default: state_next = ST_IDLE;
        endcase
    end

    // 数据通路控制：
    // 1. 在 IDLE 锁存新的 copy 描述；
    // 2. READ 态记录读请求是否已被接受，并在响应到来时锁存读数据；
    // 3. WRITE 态推进 beat/layer/slot 三层计数器。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slot_cnt         <= 3'd0;
            beat_cnt         <= {BEAT_CNT_W{1'b0}};
            lat_depth        <= 3'd0;
            lat_slot_indices <= {MAX_LEVELS*SLOT_ID_W{1'b0}};
            lat_slot_positions <= {MAX_LEVELS*16{1'b0}};
            layer_cnt        <= 8'd0;
            rd_data_buf      <= {DATA_BUS_W{1'b0}};
            rd_req_accepted_r <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (start) begin
                        // 新的一笔 copy 启动时，复位所有遍历计数器。
                        lat_depth        <= depth;
                        lat_slot_indices <= slot_indices;
                        lat_slot_positions <= slot_positions;
                        slot_cnt         <= 3'd0;
                        beat_cnt         <= {BEAT_CNT_W{1'b0}};
                        layer_cnt        <= 8'd0;
                        rd_req_accepted_r <= 1'b0;
                    end
                end

                ST_READ_BEAT: begin
                    // 读请求一旦被下游 ready 接住，就置位 accepted 标记，避免重复发起。
                    if (sram_rd_ready)
                        rd_req_accepted_r <= 1'b1;
                    if (sram_resp_valid && (rd_req_accepted_r || sram_rd_ready)) begin
                        // 收到读响应后缓存数据，准备下一状态写回。
                        rd_data_buf <= sram_resp_data;
                        rd_req_accepted_r <= 1'b0;
                    end
                end

                ST_WRITE_BEAT: begin
                    if (sram_wr_ready) begin
                        // beat 到头时，先清零 beat，再推进 layer；layer 也到头则推进 slot。
                        if (beat_cnt == KV_STRIDE[BEAT_CNT_W-1:0] - 1) begin
                            beat_cnt <= {BEAT_CNT_W{1'b0}};
                            if (layer_cnt == N_LAYERS - 1) begin
                                layer_cnt <= 8'd0;
                                slot_cnt <= slot_cnt + 3'd1;
                            end else begin
                                layer_cnt <= layer_cnt + 8'd1;
                            end
                            rd_req_accepted_r <= 1'b0;
                        end else begin
                            // 同一层内继续下一个 beat。
                            beat_cnt <= beat_cnt + {{(BEAT_CNT_W-1){1'b0}}, 1'b1};
                            rd_req_accepted_r <= 1'b0;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    // SRAM 接口输出：
    // READ 态发读，WRITE 态发写。
    assign sram_rd_valid  = (state == ST_READ_BEAT) && !rd_req_accepted_r;
    assign sram_rd_addr   = src_addr;
    assign sram_resp_ready = (state == ST_READ_BEAT);

    assign sram_wr_valid  = (state == ST_WRITE_BEAT);
    assign sram_wr_addr   = dst_addr;
    assign sram_wr_data   = rd_data_buf;

    // 状态输出。
    assign done = (state == ST_DONE);
    assign busy = (state != ST_IDLE);

endmodule
