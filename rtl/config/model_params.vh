`ifndef MODEL_PARAMS_VH
`define MODEL_PARAMS_VH

// 共享的模型侧配置头文件。
// 服务模块：compute_module、control_chip、HBM 侧数据搬运，以及数据格式相关逻辑。
// 数据格式已基本固定；层数与模型规模按当前最新讨论口径更新。

// Frozen data format choices

// 输入激活数据位宽
`define INPUT_DATA_W             8

// K/V 数据位宽
`define KV_DATA_W                8

// 输出数据位宽
`define OUTPUT_DATA_W            16

// 标记当前 KV 数据格式为 INT8
`define KV_DATA_FMT_INT8         1

// 标记当前输出数据格式为 FP16
`define OUTPUT_DATA_FMT_FP16     1

// Current architecture values

// 当前模型总层数，按最新口径改为 32 层
`define TRANSFORMER_TOTAL_LAYER_NUM  32

// 每个 chiplet 当前承担的层数，按最新口径改为 2 层
`define CHIPLET_LAYER_NUM            2

// Transformer 隐藏维度 d_model
`define DMODEL                       512

// 单个 attention head 的维度
`define HEAD_DIM                     64

// attention head 数量，512 / 64 = 8
`define HEAD_NUM                     8

// Derived helper quantity

// 每个 KV 元素占用的字节数
`define KV_BYTES_PER_ELEM        (`KV_DATA_W / 8)

// FP16 Compute Module tile dimensions
`define FP16_TILE_LANES          16
`define FP16_TILE_COLS           128
`define FP16_TILE_DATA_W         16

// Qwen3-0.6B model parameters for the staged RTL inference path.
`define QWEN3_DMODEL             1024
`define QWEN3_NUM_Q_HEADS        16
`define QWEN3_NUM_KV_HEADS       16
`define QWEN3_N_LAYERS           28
`define QWEN3_HEAD_DIM           128
`define QWEN3_INTERMEDIATE_SIZE  3072
`define QWEN3_VOCAB_SIZE         151936
`define QWEN3_MAX_POS_EMB        40960
`define QWEN3_ROPE_THETA         1000000

// Derived helper quantities for the FP16 tiled compute path.
`define QWEN3_TILE_ROWS          (`QWEN3_DMODEL / `FP16_TILE_LANES)
`define QWEN3_TILE_COL_GROUPS    (`QWEN3_DMODEL / `FP16_TILE_COLS)
`define QWEN3_FFN_TILE_ROWS      (`QWEN3_INTERMEDIATE_SIZE / `FP16_TILE_LANES)
`define QWEN3_VOCAB_TILE_ROWS    (`QWEN3_VOCAB_SIZE / `FP16_TILE_LANES)

// Toy model parameters for end-to-end RTL verification.
`define TOY_DMODEL               128
`define TOY_INTERMEDIATE_DIM     256
`define TOY_NUM_Q_HEADS          2
`define TOY_HEAD_DIM             64
`define TOY_N_LAYERS             2
`define TOY_VOCAB_SIZE           16
`define TOY_MAX_POS_EMB          32

`endif
