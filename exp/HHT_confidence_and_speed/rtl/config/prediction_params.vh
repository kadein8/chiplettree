`ifndef PREDICTION_PARAMS_VH
`define PREDICTION_PARAMS_VH

// Shared control and speculative execution configuration.
// Serves: prediction_unit, comparator, agu, prefetch_queue,
// token_register, request_controller.

// Frozen or source-backed values

// Number of speculative branches
`define BRANCH_NUM               4

// Prefetch queue depth; matches 4 branches * 4 nodes per branch window
`define PREFETCH_Q_DEPTH         24

// Max total verify nodes per branch (upper bound for hardware sizing)
`define MAX_VERIFY_NODES_PER_BRANCH  6

// Max shared prefix nodes per branch
`define MAX_SHARED_PREFIX_NODES      2

// Max private (draft) nodes per branch
`define MAX_PRIVATE_NODES_PER_BRANCH 4

// Tree-attention verify window max slot count:
// 1 (seed) + BRANCH_NUM * MAX_PRIVATE_NODES_PER_BRANCH = 17
`define VERIFY_WINDOW_SIZE           17

// Comparator output node mask width
`define NODE_MASK_W              (`BRANCH_NUM * `MAX_VERIFY_NODES_PER_BRANCH)

// Version-1 placeholders

// Token Register entry count
`define TOKEN_REG_DEPTH          96

// Request Controller internal queue depth
`define REQ_CTRL_DEPTH           48

// Free List depth
`define FREE_LIST_DEPTH          64

// Fixed control priority ordering for version 1

// flush priority
`define FLUSH_PRIO               2

// commit priority
`define COMMIT_PRIO              1

// alloc priority
`define ALLOC_PRIO               0

`endif
