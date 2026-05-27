# Makefile for speculative decode end-to-end simulation
# Supports: Verilator (WSL), VCS (VM)
#
# Usage:
#   make gen_weights    - Generate toy model weights (Python, host)
#   make golden         - Generate golden reference output (Python, host)
#   make verilator      - Compile and run with Verilator (WSL)
#   make vcs            - Compile and run with VCS (VM)
#   make compare        - Compare RTL output vs golden
#   make clean          - Remove generated files

REPO_ROOT := $(shell git rev-parse --show-toplevel 2>/dev/null || echo $(CURDIR)/../..)
RTL_DIR := $(REPO_ROOT)/code/rtl
TB_DIR := $(REPO_ROOT)/code/tb/e2e
CODE_BY_DIR := $(REPO_ROOT)/code/code_by
SCRIPT_DIR := $(REPO_ROOT)/code/script/toy_model
SIM_DIR := $(CURDIR)
GEN_DIR := $(SIM_DIR)/generated

# Python (host Windows)
PYTHON := python

# RTL source files
RTL_SRCS := \
    $(RTL_DIR)/transformer/floatMult16.v \
    $(RTL_DIR)/transformer/floatAdd16.v \
    $(RTL_DIR)/pe_operators/pe_rmsnorm_compute.v \
    $(RTL_DIR)/pe_operators/pe_silu_mul_compute.v \
    $(RTL_DIR)/pe_operators/pe_residual_add_compute.v \
    $(RTL_DIR)/pe_operators/pe_attn_compute.v \
    $(RTL_DIR)/tree_control/pe_mac_unit.v \
    $(RTL_DIR)/tree_control/pe_mac_unit_wide.v \
    $(RTL_DIR)/tree_control/PeArrayComputeOverlay.v \
    $(RTL_DIR)/tree_control/PeArrayNonlinearUnit.v \
    $(RTL_DIR)/tree_control/PeArrayLayerController.v \
    $(RTL_DIR)/tree_control/HHTContextPredictor.v \
    $(RTL_DIR)/tree_control/request_controller.v \
    $(RTL_DIR)/tree_control/multicast_network.v \
    $(RTL_DIR)/tree_control/issue_bundle_adapter.v \
    $(CODE_BY_DIR)/tree_control/tree_flatten.v \
    $(RTL_DIR)/transformer/tree_verify_dispatcher.sv \
    $(RTL_DIR)/transformer/tree_builder.sv \
    $(RTL_DIR)/transformer/feedback_controller.sv \
    $(RTL_DIR)/transformer/speculative_decode_e2e_top.sv

TB_SRCS := \
    $(TB_DIR)/tb_speculative_decode_e2e.sv

# Include paths
INC_DIRS := \
    -I$(RTL_DIR) \
    -I$(RTL_DIR)/config \
    -I$(RTL_DIR)/tree_control \
    -I$(RTL_DIR)/transformer \
    -I$(RTL_DIR)/pe_operators \
    -I$(CODE_BY_DIR) \
    -I$(CODE_BY_DIR)/tree_control \
    -I$(CODE_BY_DIR)/transformer

# =========================================================================
# Weight generation (runs on host with Python)
# =========================================================================
.PHONY: gen_weights
gen_weights:
	@mkdir -p $(GEN_DIR)
	cd $(SCRIPT_DIR) && $(PYTHON) toy_model_reference.py \
		--out-dir $(GEN_DIR) --num-tokens 4
	@echo "Weights generated in $(GEN_DIR)"

# =========================================================================
# Golden model (runs on host with Python)
# =========================================================================
.PHONY: golden
golden:
	@mkdir -p $(GEN_DIR)
	cd $(SCRIPT_DIR) && $(PYTHON) golden_speculative_decode.py \
		--out-dir $(GEN_DIR)
	@echo "Golden output generated in $(GEN_DIR)"

# =========================================================================
# Verilator (WSL)
# =========================================================================
VERILATOR := verilator
VERILATOR_FLAGS := --binary --timing -j 0 \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
    -Wno-UNDRIVEN -Wno-LATCH -Wno-CASEINCOMPLETE \
    --top-module tb_speculative_decode_e2e

VERILATOR_OBJ_DIR := $(SIM_DIR)/obj_verilator

.PHONY: verilator
verilator: gen_weights
	@mkdir -p $(VERILATOR_OBJ_DIR)
	cd $(SIM_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) \
		$(INC_DIRS) \
		$(RTL_SRCS) $(TB_SRCS) \
		--Mdir $(VERILATOR_OBJ_DIR)
	cd $(SIM_DIR) && $(VERILATOR_OBJ_DIR)/Vtb_speculative_decode_e2e
	@echo "Verilator simulation complete"

# =========================================================================
# VCS (VM)
# =========================================================================
VCS := vcs
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps \
    +v2k -debug_access+all \
    -CFLAGS "-DVCS" \
    +lint=TFIPC-L

VCS_OBJ_DIR := $(SIM_DIR)/obj_vcs

.PHONY: vcs
vcs: gen_weights
	@mkdir -p $(VCS_OBJ_DIR)
	cd $(VCS_OBJ_DIR) && $(VCS) $(VCS_FLAGS) \
		$(INC_DIRS) \
		$(RTL_SRCS) $(TB_SRCS) \
		-o simv
	cd $(VCS_OBJ_DIR) && ./simv
	@echo "VCS simulation complete"

# =========================================================================
# Compare RTL output vs golden
# =========================================================================
.PHONY: compare
compare:
	@echo "Comparing RTL output vs golden..."
	@diff -u $(GEN_DIR)/ref_token_sequence.txt rtl_output_tokens.txt && \
		echo "MATCH: RTL output matches golden" || \
		echo "MISMATCH: RTL output differs from golden"

# =========================================================================
# Clean
# =========================================================================
.PHONY: clean
clean:
	rm -rf $(VERILATOR_OBJ_DIR) $(VCS_OBJ_DIR)
	rm -f rtl_output_tokens.txt
	rm -rf $(GEN_DIR)
	@echo "Cleaned"

.PHONY: help
help:
	@echo "Targets:"
	@echo "  gen_weights  - Generate toy model weights (Python)"
	@echo "  golden       - Generate golden reference (Python)"
	@echo "  verilator    - Compile+run with Verilator (WSL)"
	@echo "  vcs          - Compile+run with VCS (VM)"
	@echo "  compare      - Diff RTL output vs golden"
	@echo "  clean        - Remove generated files"
