`ifndef INTERFACE_PARAMS_VH
`define INTERFACE_PARAMS_VH

`include "config/prediction_params.vh"

// 共享的接口位宽与表项字段配置头文件。
// 服务模块：token_register、bank_state_table、free_list、request_controller、
// comparator、control_chip、HBM bridge，以及 testbench 包装层。

// Source-backed candidate defaults already present in project design material

// 请求编号位宽
`define REQ_ID_W                 4

// token 标识位宽
`define TOKEN_ID_W               16

// token 在序列中的位置编号位宽
`define POSITION_ID_W            12

// 树节点编号位宽
`define NODE_ID_W                4

// 分支编号位宽
`define BRANCH_ID_W              2

// 层编号位宽
`define LAYER_ID_W               6

// PE 多播/广播掩码位宽
`define PE_MASK_W                16
`define MEM_REQ_LANES            `BRANCH_NUM

// Derived widths

// 单个 PE 编号位宽
`define PE_ID_W                  4

// 分支掩码位宽，通常等于分支数量
`define BRANCH_MASK_W            `BRANCH_NUM

// Tree front-end helper widths for `tree_analyze -> agu`
`define TREE_FRONTIER_SLOTS      `BRANCH_NUM
`define TREE_MAX_PREFIX_NODES    `MAX_SHARED_PREFIX_NODES
`define TREE_MAX_FRONTIER_LEVELS `MAX_VERIFY_NODES_PER_BRANCH
`define TREE_LEVEL_ID_W          2
`define TREE_SLOT_ID_W           `BRANCH_ID_W
`define TREE_PARENT_NONE_NODE_ID {`NODE_ID_W{1'b1}}

// Version-1 placeholders for interface bring-up

// Token Register 索引位宽（V1 占位值）
`define TOKEN_REG_INDEX_W        6

// 请求优先级编码位宽（V1 占位值）
`define REQ_PRIORITY_W           2

// token 生命周期状态编码位宽（V1 占位值）
`define TOKEN_STATE_W            2

// bank 状态编码位宽（V1 占位值）
`define BANK_STATE_W             2

// 共享对象引用计数位宽（V1 占位值）
`define REFCNT_W                 4

// HBM 地址位宽（V1 占位值）
`define HBM_ADDR_W               32

// HBM 数据总线位宽（V1 占位值）
`define HBM_DATA_W               256

// 片上 SRAM 读数据位宽（V1 占位值）
`define SRAM_RDATA_W             128

// 片上 SRAM 写数据位宽（V1 占位值）
`define SRAM_WDATA_W             128

`endif
