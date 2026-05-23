`ifndef INTERFACE_PARAMS_VH
`define INTERFACE_PARAMS_VH

`include "config/prediction_params.vh"

// Shared interface width and field configuration.
// Serves: token_register, bank_state_table, free_list, request_controller,
// comparator, control_chip, HBM bridge, and testbench wrappers.

// Request ID width
`define REQ_ID_W                 5

// Token ID width
`define TOKEN_ID_W               16

// Token position ID width
`define POSITION_ID_W            12

// Tree node ID width
`define NODE_ID_W                5

// Branch ID width
`define BRANCH_ID_W              2

// Layer ID width
`define LAYER_ID_W               6

// PE multicast/broadcast mask width
`define PE_MASK_W                16
`define TREE_VERIFY_PE_LANES     `PE_MASK_W
`define MEM_REQ_LANES            `TREE_VERIFY_PE_LANES

// Derived widths

// Single PE ID width
`define PE_ID_W                  4

// Branch mask width (equals branch count)
`define BRANCH_MASK_W            `BRANCH_NUM

// Tree front-end helper widths
`define TREE_FRONTIER_SLOTS      `BRANCH_NUM
`define TREE_MAX_PREFIX_NODES    `MAX_SHARED_PREFIX_NODES
`define TREE_MAX_FRONTIER_LEVELS `MAX_VERIFY_NODES_PER_BRANCH
`define TREE_LEVEL_ID_W          3
`define TREE_SLOT_ID_W           `BRANCH_ID_W
`define TREE_PARENT_NONE_NODE_ID {`NODE_ID_W{1'b1}}

// Tree-attention verify window parameters
`define TREE_MASK_DIM            `VERIFY_WINDOW_SIZE
`define SLOT_ID_W                5

// KV cache region base addresses
`define KV_COMMITTED_BASE        23'd49152
`define KV_DRAFT_BASE_MIN        23'd57344

// Version-1 placeholders for interface bring-up

// Token Register index width
`define TOKEN_REG_INDEX_W        7

// Request priority encoding width
`define REQ_PRIORITY_W           2

// Token lifecycle state encoding width
`define TOKEN_STATE_W            2

// Token register logical entry type
`define TOKEN_ENTRY_TYPE_W       1
`define TOKEN_ENTRY_TREE         1'b0
`define TOKEN_ENTRY_STREAM       1'b1

// Bank state encoding width
`define BANK_STATE_W             2

// Shared object reference count width
`define REFCNT_W                 4

// HBM address width
`define HBM_ADDR_W               32

// HBM data bus width
`define HBM_DATA_W               256

// On-chip SRAM read data width
`define SRAM_RDATA_W             128

// On-chip SRAM write data width
`define SRAM_WDATA_W             128

`endif
