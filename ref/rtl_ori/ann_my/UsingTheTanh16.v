module UsingTheTanh16 #(
    parameter DATA_WIDTH = 16,     // 数据位宽 [cite: 1]
    parameter nofinputs  = 7       // 输入数据的数量 [cite: 1]
)(
    input                                        clk,            // 时钟信号 [cite: 2]
    input                                        resetExternal,  // 外部复位信号 [cite: 1]
    input                                        start,          // 启动信号，触发 Tanh 计算 [cite: 1]
    input      signed [0:nofinputs*DATA_WIDTH-1] x,              // 拼接后的输入总线 [cite: 1]
    output reg [0:nofinputs*DATA_WIDTH-1]        Output,         // 拼接后的输出总线 [cite: 2]
    output reg                                   FinishedTanh    // 模块完成标志 [cite: 2]
);
    localparam TOTAL_WIDTH = nofinputs*DATA_WIDTH;

    // --- 内部寄存器与连线 ---
    reg        reset;        // 内部 Tanh 算子的复位控制 [cite: 2]
    reg [7:0]  i;            // 当前处理的数据索引 [cite: 3]
    reg [7:0]  counter = 0;  // 内部计数器 [cite: 2]
    reg        started;      // 内部启动保持标志
    wire       Finished;     // 单个 Tanh 计算完成的反馈信号 [cite: 2]
    wire       tanhEnable;   // 内部启动使能
    wire [DATA_WIDTH-1:0] OutputTemp; // 单个 Tanh 计算的结果缓存 [cite: 2]

    assign tanhEnable = (start || started) && (FinishedTanh == 0);

    // --- 实例化双曲正切计算模块 (Tanh) ---
    // 每次根据索引 i，从输入 x 中截取对应的 16 位数据进行计算 [cite: 3]
    HyperBolicTangent16 #(
        .DATA_WIDTH(DATA_WIDTH)
    ) TanhArray (
        .x(x[DATA_WIDTH*i +: DATA_WIDTH]),
        .reset(reset),
        .enable(tanhEnable),
        .clk(clk),
        .OutputFinal(OutputTemp),
        .Finished(Finished)
    );

    // --- 主控制逻辑 ---
    always @(posedge clk) begin
        counter <= counter + 1; // 内部时钟计数 [cite: 4]

        // 1. 外部复位逻辑 [cite: 4]
        if (resetExternal == 1) begin
            reset        <= 1;
            i            <= 0;
            FinishedTanh <= 0;
            Output       <= 0;
            started      <= 0;
        end
        else begin
            if (start == 1'b1) begin
                started <= 1'b1;
            end

            // 2. 正常运算逻辑 (如果尚未全部完成) [cite: 5]
            if (tanhEnable == 1'b1) begin
                // A. 启动/重置单个 Tanh 运算 [cite: 5]
                if (reset == 1) begin
                    reset <= 0; // 拉低复位，启动 Tanh 模块 [cite: 5]
                end
                // B. 捕获 Tanh 完成信号并处理 [cite: 6]
                else if (Finished == 1) begin
                    Output[DATA_WIDTH*i +: DATA_WIDTH] <= OutputTemp; // 将计算结果存入输出总线的对应位置 [cite: 6]
                    reset <= 1; // 准备处理下一个数据 [cite: 6]
                    i     <= i + 1; // 索引自增 [cite: 6]
                end

                // C. 检查是否处理完所有输入 [cite: 6]
                if (i == nofinputs) begin
                    FinishedTanh <= 1; // 标记本层计算结束 [cite: 6]
                end
            end
            // 原注释保留：这边缺少一个else的逻辑，不然可能会出现锁存器
        end
    end

endmodule
