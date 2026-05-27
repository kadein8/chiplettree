// -----------------------------------------------------------------------------
// 模块名称: HyperBolicTangent16
// 功能描述: 基于 FP16 的双曲正切函数实现 (分段函数 + 泰勒级数展开)
// -----------------------------------------------------------------------------
module HyperBolicTangent16 #(
    parameter DATA_WIDTH = 16
)(
    input                         clk,
    input                         reset,
    input                         enable,
    input  signed [DATA_WIDTH-1:0] x,
    output reg [DATA_WIDTH-1:0]  OutputFinal,
    output reg                    Finished
);

    // --- 局部参数 ---
    localparam taylor_iter = 4; // 泰勒级数展开项数

    // --- 内部寄存器与信号 ---
    reg [DATA_WIDTH*taylor_iter-1:0] Coefficients; // 存储 4 个 16 位系数 [cite: 9]
    reg [DATA_WIDTH-1:0]             ForXSqOrOne;  // 乘法器操作数 A：1 或 x^2 [cite: 10]
    reg [DATA_WIDTH-1:0]             ForMultPrevious; // 乘法器操作数 B：前一次的幂次结果 [cite: 11]
    reg [DATA_WIDTH-1:0]             OutputAdditionInAlways; // 累加器缓存 [cite: 14]
    reg [DATA_WIDTH-1:0]             AbsFloat;     // 输入的绝对值，用于边界判定 [cite: 17, 18]

    wire [DATA_WIDTH-1:0] Xsquared;        // x^2 的计算结果 [cite: 9]
    wire [DATA_WIDTH-1:0] OutputOne;       // 当前阶数的幂次项结果 (x, x^3, x^5...) [cite: 12]
    wire [DATA_WIDTH-1:0] OutOfCoeffMult;  // 幂次项乘以系数的结果 [cite: 13]
    wire [DATA_WIDTH-1:0] OutputAddition;  // 加法器输出结果 [cite: 14]

    // --- 硬件算子实例化 (浮点计算单元) ---
    // 1. 生成 x 的平方 [cite: 15]
    floatMult16 MSquaring (
        .floatA(x), .floatB(x), .product(Xsquared)
    );

    // 2. 迭代生成 x 的奇数次幂项 [cite: 15]
    floatMult16 MGeneratingXterm (
        .floatA(ForXSqOrOne), .floatB(ForMultPrevious), .product(OutputOne)
    );

    // 3. 将幂次项与对应的系数相乘 [cite: 15]
    floatMult16 MTheCoefficientTerm (
        .floatA(OutputOne), .floatB(Coefficients[DATA_WIDTH-1:0]), .product(OutOfCoeffMult)
    );

    // 4. 将新计算的项累加到总和中 [cite: 16]
    floatAdd16 FADD1 (
        .floatA(OutOfCoeffMult), .floatB(OutputAdditionInAlways), .sum(OutputAddition)
    );

    // --- 主控制逻辑 ---
    always @(posedge clk) begin
        if (enable == 1'b1) begin
            // 获取输入 x 的绝对值 (强制符号位为0) [cite: 18]
            AbsFloat     = x;
            AbsFloat[15] = 0;

            // --- 场景 1: 输入数值过大 (AbsFloat >= 1.57)，直接输出饱和值 ±1.0 --- [cite: 19]
            if (AbsFloat >= 16'sb0011111001001000) begin
                Finished <= 1'b1;
                if (x[15] == 0)
                    OutputFinal <= 16'b0011110000000000; // +1.0 [cite: 19]
                else
                    OutputFinal <= 16'b1011110000000000; // -1.0 [cite: 19]
            end

            // --- 场景 2: 输入在计算范围内，执行泰勒级数展开 ---
            else begin
                // A. 初始化阶段 [cite: 21]
                if (reset == 1'b1) begin
                    // 预置 4 个泰勒系数 [cite: 21]
                    Coefficients           <= 64'b1010101011101000_0011000001000100_1011010101010101_0011110000000000;
                    ForXSqOrOne            <= 16'b0011110000000000; // 常数 1.0 [cite: 21]
                    OutputAdditionInAlways <= 16'b0000000000000000; // 累加清零 [cite: 21]
                    ForMultPrevious        <= x;                   // 起始项为 x^1 [cite: 22]
                    Finished               <= 1'b0;
                end

                // B. 迭代计算阶段 [cite: 22]
                else begin
                    ForXSqOrOne            <= Xsquared;        // 之后每一项都乘 x^2 [cite: 22]
                    ForMultPrevious        <= OutputOne;       // 更新幂次项缓存 [cite: 22]
                    Coefficients           <= Coefficients >> DATA_WIDTH; // 移出已使用的系数 [cite: 22]
                    OutputAdditionInAlways <= OutputAddition;  // 更新累加和 [cite: 23]
                    Finished               <= 1'b0;
                end

                // C. 完成判定: 当所有系数移位完毕 [cite: 24]
                if (Coefficients == 64'b0) begin
                    OutputFinal <= OutputAddition;
                    Finished    <= 1'b1;
                end
            end
        end
    end

endmodule
