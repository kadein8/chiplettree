`timescale 1ns/1ps

`include "config/prediction_params.vh"
`include "config/interface_params.vh"

/*
 * 文件作用：
 * 1. 本文件实现论文 TreeControl / tree verify 路径中的 comparator。
 * 2. 它承担两类职责：
 *    - 对当前 compare slot 的 real token 与 candidate token 做逐 branch 判决，
 *      形成 commit / flush 掩码；
 *    - 在 reduce 阶段，根据 result_accept / branch path 信息归约出 accepted prefix，
 *      同时更新 live/prune branch 集合。
 * 3. 在完整路径里，它位于：
 *    operator / verify result
 *      -> comparator
 *      -> commit / flush / accepted-prefix / branch liveness
 * 4. 因此它既是“逐 slot 比较器”，又是“跨 branch 的归约器”。
 */
module comparator #(
    parameter integer PRIVATE_DEPTH_W =
        (((`MAX_VERIFY_NODES_PER_BRANCH + 1) <= 2) ? 1 :
         $clog2(`MAX_VERIFY_NODES_PER_BRANCH + 1)),
    parameter integer BRANCH_EPOCH_W = 2,
    parameter integer BRANCH_PATH_PACK_W =
        (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH * `NODE_ID_W),
    parameter integer BRANCH_DEPTH_PACK_W = (`BRANCH_NUM * PRIVATE_DEPTH_W),
    parameter integer BRANCH_EPOCH_PACK_W = (`BRANCH_NUM * BRANCH_EPOCH_W)
) (
    // 时钟与复位。
    input                         clk,
    input                         rst_n,

    // 当前 compare 输入：
    // 每个 slot 携带一个 real token、candidate token、node_id、branch_id。
    input  [`REQ_ID_W-1:0]        cmp_req_id,
    input  [`BRANCH_NUM-1:0]      cmp_slot_valid,
    input  [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_real_token_id,
    input  [`BRANCH_NUM*`TOKEN_ID_W-1:0] cmp_slot_candidate_token_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_node_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0]  cmp_slot_parent_node_id,
    input  [`BRANCH_NUM*`BRANCH_ID_W-1:0] cmp_slot_branch_id,

    // reduce 起始输入：
    // active_branch_* 描述本轮归约开始时各 branch 当前仍活着的路径状态。
    input                         reduce_start_valid,
    input  [`REQ_ID_W-1:0]        reduce_req_id,
    input  [`BRANCH_NUM-1:0]      active_branch_valid,
    input  [BRANCH_EPOCH_PACK_W-1:0] active_branch_epoch,
    input  [BRANCH_DEPTH_PACK_W-1:0] active_branch_depth,
    input  [BRANCH_PATH_PACK_W-1:0] active_branch_node_id,
    input  [BRANCH_PATH_PACK_W-1:0] active_branch_parent_node_id,

    // result_*：
    // 上游验证/执行结果，表示各 branch 在某个 private depth 上是否 accept。
    input  [`BRANCH_NUM-1:0]      result_slot_valid,
    input  [`REQ_ID_W-1:0]        result_req_id,
    input  [`BRANCH_NUM*`BRANCH_ID_W-1:0] result_branch_id,
    input  [BRANCH_EPOCH_PACK_W-1:0] result_branch_epoch,
    input  [BRANCH_DEPTH_PACK_W-1:0] result_private_depth,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0] result_node_id,
    input  [`BRANCH_NUM*`NODE_ID_W-1:0] result_parent_node_id,
    input  [`BRANCH_NUM-1:0]      result_accept,

    // 输出：
    // commit/flush 掩码、accepted prefix，以及最新 live/prune branch。
    output                        commit_valid,
    output [`BRANCH_MASK_W-1:0]   commit_branch_mask,
    output [`NODE_MASK_W-1:0]     commit_node_mask,
    output                        flush_valid,
    output [`BRANCH_MASK_W-1:0]   flush_branch_mask,
    output [`NODE_MASK_W-1:0]     flush_node_mask,
    output                        accepted_prefix_valid,
    output [`REQ_ID_W-1:0]        accepted_prefix_req_id,
    output [PRIVATE_DEPTH_W-1:0]  accepted_prefix_depth,
    output [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id,
    output [`BRANCH_NUM-1:0]      live_branch_mask,
    output [`BRANCH_NUM-1:0]      prune_branch_mask
);

// 组合形成的 commit/flush 输出。
reg commit_valid_comb;
reg [`BRANCH_MASK_W-1:0] commit_branch_mask_comb;
reg [`NODE_MASK_W-1:0] commit_node_mask_comb;
reg flush_valid_comb;
reg [`BRANCH_MASK_W-1:0] flush_branch_mask_comb;
reg [`NODE_MASK_W-1:0] flush_node_mask_comb;

// 当前正在处理的 cmp slot 的临时字段。
reg [`TOKEN_ID_W-1:0] slot_real_token_id_comb;
reg [`TOKEN_ID_W-1:0] slot_candidate_token_id_comb;
reg [`NODE_ID_W-1:0] slot_node_id_comb;
reg [`BRANCH_ID_W-1:0] slot_branch_id_comb;
reg slot_token_match_comb;

// 已归约状态寄存器：
// 表示当前 req_id 的活分支集合、各 branch epoch/depth/path 以及已接受前缀。
reg [`REQ_ID_W-1:0] current_req_id_state;
reg [`BRANCH_NUM-1:0] live_branch_mask_state;
reg [BRANCH_EPOCH_PACK_W-1:0] branch_epoch_state;
reg [BRANCH_DEPTH_PACK_W-1:0] branch_depth_state;
reg [BRANCH_PATH_PACK_W-1:0] branch_node_id_state;
reg [BRANCH_PATH_PACK_W-1:0] branch_parent_node_id_state;
reg accepted_prefix_valid_state;
reg [PRIVATE_DEPTH_W-1:0] accepted_prefix_depth_state;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] accepted_prefix_node_id_state;

// 本拍归约的基准状态：
// 默认来自 state_*，若 reduce_start_valid 拉高，则用 active_branch_* 覆盖为本轮新的起点。
reg [`REQ_ID_W-1:0] base_req_id_comb;
reg [`BRANCH_NUM-1:0] base_live_branch_mask_comb;
reg [BRANCH_EPOCH_PACK_W-1:0] base_branch_epoch_comb;
reg [BRANCH_DEPTH_PACK_W-1:0] base_branch_depth_comb;
reg [BRANCH_PATH_PACK_W-1:0] base_branch_node_id_comb;
reg [BRANCH_PATH_PACK_W-1:0] base_branch_parent_node_id_comb;
reg base_accepted_prefix_valid_comb;
reg [PRIVATE_DEPTH_W-1:0] base_accepted_prefix_depth_comb;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] base_accepted_prefix_node_id_comb;

// 本拍归约后的 next 状态。
reg [`REQ_ID_W-1:0] next_req_id_comb;
reg [`BRANCH_NUM-1:0] next_live_branch_mask_comb;
reg [BRANCH_EPOCH_PACK_W-1:0] next_branch_epoch_comb;
reg [BRANCH_DEPTH_PACK_W-1:0] next_branch_depth_comb;
reg [BRANCH_PATH_PACK_W-1:0] next_branch_node_id_comb;
reg [BRANCH_PATH_PACK_W-1:0] next_branch_parent_node_id_comb;
reg next_accepted_prefix_valid_comb;
reg [PRIVATE_DEPTH_W-1:0] next_accepted_prefix_depth_comb;
reg [(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W)-1:0] next_accepted_prefix_node_id_comb;

// accepted prefix 归约中间量。
reg accepted_update_found_comb;
reg [`BRANCH_ID_W-1:0] accepted_branch_id_comb;
reg [PRIVATE_DEPTH_W-1:0] accepted_result_depth_comb;
reg [BRANCH_EPOCH_W-1:0] accepted_result_epoch_comb;
reg result_req_id_matches_state_comb;
reg branch_is_compatible_comb;
reg branch_epoch_match_comb;

// 循环变量。
integer slot_i;
integer result_slot_i;
integer branch_i;
integer depth_i;

// branch_id -> branch mask onehot。
function [`BRANCH_MASK_W-1:0] branch_onehot_mask;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_onehot_mask = {`BRANCH_MASK_W{1'b0}};
        if (branch_id_in < `BRANCH_NUM) begin
            branch_onehot_mask[branch_id_in] = 1'b1;
        end
    end
endfunction

// (branch_id,node_id) -> node_mask onehot。
function [`NODE_MASK_W-1:0] node_onehot_mask;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input [`NODE_ID_W-1:0] node_id_in;
    integer bit_index_i;
    begin
        node_onehot_mask = {`NODE_MASK_W{1'b0}};
        bit_index_i = (branch_id_in * `MAX_VERIFY_NODES_PER_BRANCH) + node_id_in;
        if ((branch_id_in < `BRANCH_NUM) &&
            (node_id_in < `MAX_VERIFY_NODES_PER_BRANCH) &&
            (bit_index_i < `NODE_MASK_W)) begin
            node_onehot_mask[bit_index_i] = 1'b1;
        end
    end
endfunction

// 从打包总线里取某个 branch 的 private depth。
function [PRIVATE_DEPTH_W-1:0] branch_depth_of;
    input [BRANCH_DEPTH_PACK_W-1:0] depth_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_depth_of = depth_bus_in[(branch_id_in*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W];
    end
endfunction

// 从打包总线里取某个 branch 的 epoch。
function [BRANCH_EPOCH_W-1:0] branch_epoch_of;
    input [BRANCH_EPOCH_PACK_W-1:0] epoch_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    begin
        branch_epoch_of = epoch_bus_in[(branch_id_in*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W];
    end
endfunction

// 从打包路径总线里取某个 branch 在某个 depth 上的 node_id。
function [`NODE_ID_W-1:0] branch_path_node_of;
    input [BRANCH_PATH_PACK_W-1:0] path_bus_in;
    input [`BRANCH_ID_W-1:0] branch_id_in;
    input integer depth_idx_in;
    begin
        branch_path_node_of =
            path_bus_in[(((branch_id_in*`MAX_VERIFY_NODES_PER_BRANCH) + depth_idx_in)*`NODE_ID_W) +: `NODE_ID_W];
    end
endfunction

// compare 组合逻辑：
// 对每个有效 cmp slot 做 token 比较。
// 1. real == candidate : 该 branch/node 进入 commit 掩码。
// 2. real != candidate : 该 branch/node 进入 flush 掩码。
always @* begin
    commit_valid_comb = 1'b0;
    commit_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    commit_node_mask_comb = {`NODE_MASK_W{1'b0}};
    flush_valid_comb = 1'b0;
    flush_branch_mask_comb = {`BRANCH_MASK_W{1'b0}};
    flush_node_mask_comb = {`NODE_MASK_W{1'b0}};

    slot_real_token_id_comb = {`TOKEN_ID_W{1'b0}};
    slot_candidate_token_id_comb = {`TOKEN_ID_W{1'b0}};
    slot_node_id_comb = {`NODE_ID_W{1'b0}};
    slot_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    slot_token_match_comb = 1'b0;

    for (slot_i = 0; slot_i < `BRANCH_NUM; slot_i = slot_i + 1) begin
        if (cmp_slot_valid[slot_i]) begin
            // 取当前 slot 的 real/candidate/node/branch。
            slot_real_token_id_comb =
                cmp_slot_real_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
            slot_candidate_token_id_comb =
                cmp_slot_candidate_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W];
            slot_node_id_comb =
                cmp_slot_node_id[(slot_i*`NODE_ID_W) +: `NODE_ID_W];
            slot_branch_id_comb =
                cmp_slot_branch_id[(slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
            slot_token_match_comb =
                (cmp_slot_real_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W] ==
                 cmp_slot_candidate_token_id[(slot_i*`TOKEN_ID_W) +: `TOKEN_ID_W]);

            if (slot_token_match_comb) begin
                // token 命中：加入 commit。
                commit_valid_comb = 1'b1;
                commit_branch_mask_comb =
                    commit_branch_mask_comb | branch_onehot_mask(slot_branch_id_comb);
                commit_node_mask_comb =
                    commit_node_mask_comb | node_onehot_mask(slot_branch_id_comb, slot_node_id_comb);
            end else begin
                // token 不命中：加入 flush。
                flush_valid_comb = 1'b1;
                flush_branch_mask_comb =
                    flush_branch_mask_comb | branch_onehot_mask(slot_branch_id_comb);
                flush_node_mask_comb =
                    flush_node_mask_comb | node_onehot_mask(slot_branch_id_comb, slot_node_id_comb);
            end
        end
    end
end

// reduce / accepted-prefix 归约逻辑：
// 1. 选择基准状态（state 或 active_branch_*）；
// 2. 在 result_accept 中找出“最深、且与当前 branch path 一致”的 accept 结果；
// 3. 以该结果为 accepted prefix，筛掉所有不兼容的 branch。
always @* begin
    base_req_id_comb = current_req_id_state;
    base_live_branch_mask_comb = live_branch_mask_state;
    base_branch_epoch_comb = branch_epoch_state;
    base_branch_depth_comb = branch_depth_state;
    base_branch_node_id_comb = branch_node_id_state;
    base_branch_parent_node_id_comb = branch_parent_node_id_state;
    base_accepted_prefix_valid_comb = accepted_prefix_valid_state;
    base_accepted_prefix_depth_comb = accepted_prefix_depth_state;
    base_accepted_prefix_node_id_comb = accepted_prefix_node_id_state;

    if (reduce_start_valid === 1'b1) begin
        // 新一轮 reduce 启动时，用 active_branch_* 作为归约起点。
        base_req_id_comb = reduce_req_id;
        base_live_branch_mask_comb = active_branch_valid;
        base_branch_epoch_comb = active_branch_epoch;
        base_branch_depth_comb = active_branch_depth;
        base_branch_node_id_comb = active_branch_node_id;
        base_branch_parent_node_id_comb = active_branch_parent_node_id;
        base_accepted_prefix_valid_comb = 1'b0;
        base_accepted_prefix_depth_comb = {PRIVATE_DEPTH_W{1'b0}};
        base_accepted_prefix_node_id_comb =
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    end

    // 默认 next 状态先等于 base 状态。
    next_req_id_comb = base_req_id_comb;
    next_live_branch_mask_comb = base_live_branch_mask_comb;
    next_branch_epoch_comb = base_branch_epoch_comb;
    next_branch_depth_comb = base_branch_depth_comb;
    next_branch_node_id_comb = base_branch_node_id_comb;
    next_branch_parent_node_id_comb = base_branch_parent_node_id_comb;
    next_accepted_prefix_valid_comb = base_accepted_prefix_valid_comb;
    next_accepted_prefix_depth_comb = base_accepted_prefix_depth_comb;
    next_accepted_prefix_node_id_comb = base_accepted_prefix_node_id_comb;

    accepted_update_found_comb = 1'b0;
    accepted_branch_id_comb = {`BRANCH_ID_W{1'b0}};
    accepted_result_depth_comb = {PRIVATE_DEPTH_W{1'b0}};
    accepted_result_epoch_comb = {BRANCH_EPOCH_W{1'b0}};
    result_req_id_matches_state_comb = 1'b1;

    // 如果 result_req_id 不是 X，则要求它必须与当前 req_id 对齐。
    if (!(^result_req_id === 1'bx)) begin
        result_req_id_matches_state_comb = (result_req_id == base_req_id_comb);
    end

    for (result_slot_i = 0; result_slot_i < `BRANCH_NUM; result_slot_i = result_slot_i + 1) begin
        // 筛选条件：
        // 1. slot/result/accept 都有效；
        // 2. branch 仍在 live 集合中；
        // 3. private depth 非 0，且不超过该 branch 当前路径深度；
        // 4. epoch 匹配；
        // 5. 该 result 的 node_id 必须等于该 branch 在对应 depth 处的路径节点。
        if ((result_slot_valid[result_slot_i] === 1'b1) &&
            result_req_id_matches_state_comb &&
            (result_accept[result_slot_i] === 1'b1) &&
            (result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W] < `BRANCH_NUM) &&
            (base_live_branch_mask_comb[result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]] === 1'b1) &&
            (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] != {PRIVATE_DEPTH_W{1'b0}}) &&
            (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] <=
             branch_depth_of(
                 base_branch_depth_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]
             )) &&
            (result_branch_epoch[(result_slot_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] ==
             branch_epoch_of(
                 base_branch_epoch_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W]
             )) &&
            (result_node_id[(result_slot_i*`NODE_ID_W) +: `NODE_ID_W] ==
             branch_path_node_of(
                 base_branch_node_id_comb,
                 result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W],
                 result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] - 1
             ))) begin
            if ((!accepted_update_found_comb) ||
                (result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W] >
                 accepted_result_depth_comb)) begin
                // 选择“最深”的那个 accept 结果作为 accepted prefix。
                accepted_update_found_comb = 1'b1;
                accepted_branch_id_comb =
                    result_branch_id[(result_slot_i*`BRANCH_ID_W) +: `BRANCH_ID_W];
                accepted_result_depth_comb =
                    result_private_depth[(result_slot_i*PRIVATE_DEPTH_W) +: PRIVATE_DEPTH_W];
                accepted_result_epoch_comb =
                    result_branch_epoch[(result_slot_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W];
            end
        end
    end

    if (accepted_update_found_comb) begin
        // 已找到 accepted prefix：
        // 把对应 branch 的前 accepted_result_depth_comb 个节点拷成 accepted_prefix。
        next_accepted_prefix_valid_comb = 1'b1;
        next_accepted_prefix_depth_comb = accepted_result_depth_comb;
        next_accepted_prefix_node_id_comb =
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};

        for (depth_i = 0; depth_i < `MAX_VERIFY_NODES_PER_BRANCH; depth_i = depth_i + 1) begin
            if (depth_i < accepted_result_depth_comb) begin
                // accepted prefix 的第 depth_i 个节点来自 accepted_branch 的路径。
                next_accepted_prefix_node_id_comb[(depth_i*`NODE_ID_W) +: `NODE_ID_W] =
                    branch_path_node_of(base_branch_node_id_comb, accepted_branch_id_comb, depth_i);
            end
        end

        // 之后重新计算 live_branch_mask：
        // 只有 epoch 相同、depth 足够、且前缀路径完全匹配 accepted prefix 的 branch 才能继续活着。
        next_live_branch_mask_comb = {`BRANCH_NUM{1'b0}};

        for (branch_i = 0; branch_i < `BRANCH_NUM; branch_i = branch_i + 1) begin
            branch_is_compatible_comb = 1'b0;
            branch_epoch_match_comb = 1'b0;

            if (base_live_branch_mask_comb[branch_i] === 1'b1) begin
                branch_epoch_match_comb =
                    (base_branch_epoch_comb[(branch_i*BRANCH_EPOCH_W) +: BRANCH_EPOCH_W] ==
                     accepted_result_epoch_comb);
                branch_is_compatible_comb = branch_epoch_match_comb;

                if (branch_depth_of(base_branch_depth_comb, branch_i) <
                    accepted_result_depth_comb) begin
                    branch_is_compatible_comb = 1'b0;
                end

                if (branch_is_compatible_comb) begin
                    for (depth_i = 0; depth_i < `MAX_VERIFY_NODES_PER_BRANCH; depth_i = depth_i + 1) begin
                        if (depth_i < accepted_result_depth_comb) begin
                            // 任何一个前缀节点不匹配，都说明该 branch 需要被 prune。
                            if (branch_path_node_of(
                                    base_branch_node_id_comb,
                                    branch_i,
                                    depth_i
                                ) !=
                                next_accepted_prefix_node_id_comb[(depth_i*`NODE_ID_W) +: `NODE_ID_W]) begin
                                branch_is_compatible_comb = 1'b0;
                            end
                        end
                    end
                end

                if (branch_is_compatible_comb) begin
                    // 完全兼容 accepted prefix 的 branch 保持 live。
                    next_live_branch_mask_comb[branch_i] = 1'b1;
                end
            end
        end
    end
end

// 时序寄存器：
// 把本拍算出的 next reduce 状态落入 state_*。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 复位时清空 req、branch 状态和 accepted prefix。
        current_req_id_state <= {`REQ_ID_W{1'b0}};
        live_branch_mask_state <= {`BRANCH_NUM{1'b0}};
        branch_epoch_state <= {BRANCH_EPOCH_PACK_W{1'b0}};
        branch_depth_state <= {BRANCH_DEPTH_PACK_W{1'b0}};
        branch_node_id_state <= {BRANCH_PATH_PACK_W{1'b0}};
        branch_parent_node_id_state <= {BRANCH_PATH_PACK_W{1'b0}};
        accepted_prefix_valid_state <= 1'b0;
        accepted_prefix_depth_state <= {PRIVATE_DEPTH_W{1'b0}};
        accepted_prefix_node_id_state <=
            {(`MAX_VERIFY_NODES_PER_BRANCH*`NODE_ID_W){1'b0}};
    end else begin
        // 正常时每拍更新到最新归约状态。
        current_req_id_state <= next_req_id_comb;
        live_branch_mask_state <= next_live_branch_mask_comb;
        branch_epoch_state <= next_branch_epoch_comb;
        branch_depth_state <= next_branch_depth_comb;
        branch_node_id_state <= next_branch_node_id_comb;
        branch_parent_node_id_state <= next_branch_parent_node_id_comb;
        accepted_prefix_valid_state <= next_accepted_prefix_valid_comb;
        accepted_prefix_depth_state <= next_accepted_prefix_depth_comb;
        accepted_prefix_node_id_state <= next_accepted_prefix_node_id_comb;
    end
end

// 组合结果直接导出。
assign commit_valid = commit_valid_comb;
assign commit_branch_mask = commit_branch_mask_comb;
assign commit_node_mask = commit_node_mask_comb;
assign flush_valid = flush_valid_comb;
assign flush_branch_mask = flush_branch_mask_comb;
assign flush_node_mask = flush_node_mask_comb;

assign accepted_prefix_valid = next_accepted_prefix_valid_comb;
assign accepted_prefix_req_id = next_req_id_comb;
assign accepted_prefix_depth = next_accepted_prefix_depth_comb;
assign accepted_prefix_node_id = next_accepted_prefix_node_id_comb;
assign live_branch_mask = next_live_branch_mask_comb;

// prune_branch_mask 表示“原来 live、现在不再 live”的那些 branch。
assign prune_branch_mask = base_live_branch_mask_comb & (~next_live_branch_mask_comb);

endmodule
