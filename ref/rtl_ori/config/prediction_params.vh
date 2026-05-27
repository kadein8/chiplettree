`ifndef PREDICTION_PARAMS_VH
`define PREDICTION_PARAMS_VH

// 共享的控制与推测执行侧配置头文件。
// 服务模块：prediction_unit、comparator、agu、prefetch_queue、
// token_register、request_controller。

// Frozen or source-backed values

// 推测执行时支持的分支数量
`define BRANCH_NUM               4

// 预取队列深度；当前与 4 分支 * 每分支 4 节点 的窗口规模对应
`define PREFETCH_Q_DEPTH         16

// 单个分支验证时的总节点数上限，按文档取 4
`define MAX_VERIFY_NODES_PER_BRANCH  4

// 单个分支中最多共享前缀节点数，按文档取 2
`define MAX_SHARED_PREFIX_NODES      2

// 单个分支中最多私有节点数，按文档取 2
`define MAX_PRIVATE_NODES_PER_BRANCH 2

// comparator 杈撳嚭鐨勮妭鐐规帺鐮佹€诲搴︼紝鎸夋墍鏈夊垎鏀獙璇佽妭鐐规€绘暟鎺ㄥ
`define NODE_MASK_W              (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH)

// Version-1 placeholders

// Token Register 表项数量（V1 占位值）
`define TOKEN_REG_DEPTH          64

// Request Controller 内部队列/表项深度（V1 占位值）
`define REQ_CTRL_DEPTH           32

// Free List 深度（V1 占位值）
`define FREE_LIST_DEPTH          32

// Fixed control priority ordering for version 1

// flush 控制优先级
`define FLUSH_PRIO               2

// commit 控制优先级
`define COMMIT_PRIO              1

// alloc 控制优先级
`define ALLOC_PRIO               0

`endif
