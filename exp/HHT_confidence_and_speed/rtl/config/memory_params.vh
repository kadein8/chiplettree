`ifndef MEMORY_PARAMS_VH
`define MEMORY_PARAMS_VH

// 共享的存储侧配置头文件。
// 服务模块：sram_subsystem、sram_bank、sram_subbank、free_list、
// bank_state_table、request_controller。
// 已冻结的架构参数会直接写死。
// 仍未最终拍板的参数保留为 V1 占位值，后续需要回到设计文档同步更新。

// Frozen values

// 片上 SRAM 切片数量
`define SRAM_NUM                 4

// 每片 SRAM 的物理容量，当前按 2MB 记
`define SRAM_SIZE_BYTES          2097152

// 每片 SRAM 内的 bank 数量
`define SRAM_BANK_NUM            16

// 每个 bank 每周期支持的读端口数
`define BANK_RD_PORTS            1

// 每个 bank 每周期支持的写端口数
`define BANK_WR_PORTS            1

// 读请求被接受后首拍数据返回延迟（单位：cycle）
`define MEM_READ_FIRST_BEAT_LAT  1

// Version-1 placeholders

// 当前 V1 仍用 4KB 作为 sub-bank 占位容量；若后续改粒度，需要同步调整
`define SUBBANK_SIZE_BYTES       4096

// 2MB / 16 bank = 128KB/bank；若每个 sub-bank 为 4KB，则每个 bank 为 32 个 sub-bank
`define SUBBANK_NUM_PER_BANK     32

// 一个 kv_group 默认占用的连续 sub-bank 数（当前 V1 先按 2 个占位）
`define KV_GROUP_SIZE_SUBBANK    2

// 当前片上 SRAM 数据拍宽度 128bit = 16B，因此行内字节偏移位宽先取 4
`define OFFSET_W                 4

// 4KB sub-bank / 16B 每拍 = 256 个 beat，因此行地址位宽先取 8
`define ROW_ADDR_W               8

// Derived widths

// 选择第几片 SRAM 所需的位宽
`define SRAM_ID_W                2

// 选择 bank 所需的位宽
`define BANK_ID_W                4

// 选择 sub-bank 所需的位宽；32 个 sub-bank 需要 5bit
`define SUBBANK_ID_W             5

// 表示 kv_group 包含多少个 sub-bank 的位宽
`define KV_GROUP_LEN_W           4

// bank 占用位图宽度，通常等于 sub-bank 数量
`define BANK_OCC_BITMAP_W        `SUBBANK_NUM_PER_BANK

// 当前单个 kv_group 的总字节数（由配置推导）
`define KV_GROUP_SIZE_BYTES      (`KV_GROUP_SIZE_SUBBANK * `SUBBANK_SIZE_BYTES)

// 当前片上 SRAM 每拍可传输的字节数（由数据位宽推导）
`define SRAM_BEAT_BYTES          (`SRAM_RDATA_W / 8)

// 一个 kv_group 完整搬运所需的拍数上限（模块内部推导，不作为顶层接口字段）
`define KV_GROUP_BURST_BEATS     (`KV_GROUP_SIZE_BYTES / `SRAM_BEAT_BYTES)

// Effective address packing:
// `sram_id | bank_id | subbank_id | row_addr | offset`

// 片上 SRAM 统一地址总位宽
`define SRAM_ADDR_W              (`SRAM_ID_W + `BANK_ID_W + `SUBBANK_ID_W + `ROW_ADDR_W + `OFFSET_W)

`endif
