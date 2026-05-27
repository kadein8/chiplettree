// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Primary design header
//
// This header should be included by all source files instantiating the design.
// The class here is then constructed to instantiate the design.
// See the Verilator manual for examples.

#ifndef _VSPECULATIVE_DECODE_E2E_TOP_H_
#define _VSPECULATIVE_DECODE_E2E_TOP_H_  // guard

#include "verilated.h"
#include "Vspeculative_decode_e2e_top__Dpi.h"

//==========

class Vspeculative_decode_e2e_top__Syms;
class Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10;


//----------

VL_MODULE(Vspeculative_decode_e2e_top) {
  public:
    // CELLS
    // Public to allow access to /*verilator_public*/ items;
    // otherwise the application code can consider these internals.
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10* __PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__0__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10* __PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__1__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10* __PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__2__KET____DOT__u_mac;
    Vspeculative_decode_e2e_top_pe_mac_unit__L8_D100_DB10* __PVT__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gen_slot_mac__BRA__3__KET____DOT__u_mac;
    
    // PORTS
    // The application code writes and reads these signals to
    // propagate new values into/out from the Verilated model.
    VL_IN8(clk,0,0);
    VL_IN8(rst_n,0,0);
    VL_IN8(start,0,0);
    VL_IN8(max_gen_tokens,7,0);
    VL_OUT8(done,0,0);
    VL_OUT8(busy,0,0);
    VL_OUT8(token_out_valid,0,0);
    VL_OUT8(sram_rd_valid,0,0);
    VL_IN8(sram_rd_ready,0,0);
    VL_IN8(sram_resp_valid,0,0);
    VL_OUT8(sram_wr_valid,0,0);
    VL_IN8(sram_wr_ready,0,0);
    VL_OUT8(hbm_rd_valid,0,0);
    VL_IN8(hbm_rd_ready,0,0);
    VL_IN8(hbm_resp_valid,0,0);
    VL_IN16(prompt_token_id,15,0);
    VL_OUT16(token_out_id,15,0);
    VL_OUT(sram_rd_addr,22,0);
    VL_INW(sram_resp_data,127,0,4);
    VL_OUT(sram_wr_addr,22,0);
    VL_OUTW(sram_wr_data,127,0,4);
    VL_OUT(hbm_rd_addr,31,0);
    VL_INW(hbm_resp_data,255,0,8);
    
    // LOCAL SIGNALS
    // Internals; generally not touched by application code
    // Anonymous structures to workaround compiler member-count bugs
    struct {
        CData/*3:0*/ speculative_decode_e2e_top__DOT__state_r;
        CData/*7:0*/ speculative_decode_e2e_top__DOT__gen_count_r;
        CData/*7:0*/ speculative_decode_e2e_top__DOT__max_gen_r;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__seed_node_id_r;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__hht_accept_valid;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__hht_accept_parent_node_id;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__hht_cand_valid;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__hht_cand_parent_node_id;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__tb_start;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__tb_done;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__tb_busy;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__tb_tree_req_valid;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__tvd_fwd_result_valid;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__fb_done;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__fb_out_token_valid;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__fb_new_seed_valid;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__fb_new_seed_node_id;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__fb_hht_accept_valid;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__fb_hht_accept_parent_node_id;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__lc_done;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__lc_start;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__lc_busy;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__lc_slot_valid;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__lc_out_token_valid;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__history_count_r;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__history_parent_1_r;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__lookup_hit_w;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__lookup_hit_index_w;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__victim_index_w;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__invalid_found_w;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__invalid_index_w;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__state_r;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_active_r;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__next_node_id_r;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__found_branch;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__target_branch;
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__state;
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__state_next;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_seed_node_id;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_valid;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_unique_slot_count;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__best_branch;
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__best_depth;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__cur_slot_idx;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__winner_last_slot_idx;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__winner_predict_slot_idx;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__mismatch_found;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__alloc_count;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__found;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__matched_slot;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__cur_node_id;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__cur_parent_node_id;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__cur_parent_slot;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__found_parent;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__state_r;
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__emit_idx_r;
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__win_branch_r;
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__win_depth_r;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__cur_node_w;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__cur_parent_w;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__state_r;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__op_r;
        CData/*5:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__layer_idx_r;
        CData/*5:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__out_group_r;
    };
    struct {
        CData/*1:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__load_slot_r;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__active_slots_r;
        CData/*5:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_output_groups_r;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mac_clear;
        CData/*3:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mac_valid;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__sub_started_r;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__norm_done_w;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__res_done_w;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__silu_done_w;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__seed_token_id_r;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__seed_position_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__committed_prefix_len_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__hht_accept_token_id;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__hht_accept_position;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__fb_out_token_id;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__fb_new_seed_token_id;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__fb_new_seed_position;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__fb_hht_accept_token_id;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__fb_hht_accept_position;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__history_token_0_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__history_token_1_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__lru_counter_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__victim_lru_w;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__lookup_hash_w;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__next_lru_w;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__timeout_cnt_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__levels_valid_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_seed_token_id;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_seed_position;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_levels_valid;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__bonus_token;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__draft_tok;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__model_tok;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__cur_token_id;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__cur_position;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__bonus_token_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__cur_token_w;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_feedback__DOT__cur_position_w;
        SData/*8:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__beat_cnt_r;
        SData/*8:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__resp_cnt_r;
        SData/*8:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_input_dim_r;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__argmax_elem_r;
        WData/*543:0*/ speculative_decode_e2e_top__DOT__tvd_batch_out_token_ids[17];
        WData/*271:0*/ speculative_decode_e2e_top__DOT__tvd_batch_out_positions[9];
        WData/*543:0*/ speculative_decode_e2e_top__DOT__tvd_fwd_result_token_ids[17];
        IData/*31:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__lookup_entry_idx;
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__node_ids_r[3];
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__parent_node_ids_r[3];
        WData/*255:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__draft_tokens_r[8];
        WData/*191:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__draft_positions_r[6];
        IData/*31:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__unnamedblk1__DOT__flat_idx;
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_node_ids[3];
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_parent_node_ids[3];
        WData/*255:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_draft_tokens[8];
        WData/*191:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_draft_positions[6];
        WData/*271:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_slot_token_id[9];
        WData/*203:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_slot_position[7];
        WData/*84:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_slot_parent_slot[3];
        IData/*16:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_slot_is_seed;
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__flat_branch_slot_map[3];
        WData/*271:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_slot_token_id[9];
        WData/*203:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_slot_position[7];
        WData/*79:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_branch_slot_map[3];
        WData/*543:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__lat_fwd_token_ids[17];
    };
    struct {
        IData/*31:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__b;
        WData/*2047:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gamma_r[64];
        IData/*22:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_weight_base_r;
        WData/*127:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mac_weight_col[4];
        WData/*511:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mac_result[16];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__norm_vec_in_w[256];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__norm_vec_out_w[256];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__res_vec_a_w[256];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__res_vec_b_w[256];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__res_vec_out_w[256];
        WData/*16383:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__silu_gate_w[512];
        WData/*16383:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__silu_up_w[512];
        WData/*16383:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__silu_out_w[512];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_rmsnorm__DOT__dpi_out[256];
        WData/*8191:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_residual__DOT__dpi_out[256];
        WData/*16383:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_silu_mul__DOT__dpi_out[512];
        QData/*63:0*/ speculative_decode_e2e_top__DOT__lc_slot_token_id;
        QData/*63:0*/ speculative_decode_e2e_top__DOT__lc_out_token_id;
        QData/*63:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__cmp_commit_slot_positions;
        QData/*63:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__lat_token_id_r;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__entry_valid_r[4];
        SData/*14:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__entry_tag_r[4];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r[4];
        CData/*7:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__entry_confidence_r[4];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_hht__DOT__entry_last_use_r[4];
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_tip_node_r[4];
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_depth_r[4];
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__branch_accept_depth[4];
        CData/*2:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__branch_total_depth[4];
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__alloc_node_id[17];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__alloc_token_id[17];
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__alloc_position[17];
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT__alloc_parent[17];
        WData/*2047:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r[4][64];
        WData/*2047:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_residual_r[4][64];
        WData/*2047:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r[4][64];
        WData/*4095:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r[4][128];
        WData/*4095:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_up_r[4][128];
        WData/*4095:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r[4][128];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mac_vec_sel[4];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r[4];
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_idx_r[4];
    };
    
    // LOCAL VARIABLES
    // Internals; generally not touched by application code
    // Anonymous structures to workaround compiler member-count bugs
    struct {
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT____Vlvbound1;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT____Vlvbound2;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound5;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound8;
        CData/*0:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound9;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound10;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound13;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound14;
        CData/*4:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound15;
        CData/*5:0*/ __Vtableidx1;
        CData/*7:0*/ __Vdly__speculative_decode_e2e_top__DOT__gen_count_r;
        CData/*3:0*/ __Vdly__speculative_decode_e2e_top__DOT__state_r;
        CData/*4:0*/ __Vdly__speculative_decode_e2e_top__DOT__seed_node_id_r;
        CData/*1:0*/ __Vdlyvdim0__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v0;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v0;
        CData/*1:0*/ __Vdlyvdim0__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v1;
        CData/*1:0*/ __Vdlyvdim0__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v2;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v2;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v3;
        CData/*1:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__state_r;
        CData/*3:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_active_r;
        CData/*4:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__next_node_id_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_tip_node_r__v0;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_tip_node_r__v4;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__branch_tip_node_r__v5;
        CData/*1:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_feedback__DOT__state_r;
        CData/*0:0*/ __Vdly__speculative_decode_e2e_top__DOT__lc_done;
        CData/*4:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__state_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v0;
        CData/*4:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__op_r;
        CData/*5:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_output_groups_r;
        CData/*5:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__out_group_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v0;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_up_r__v0;
        CData/*0:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__sub_started_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_up_r__v1;
        CData/*0:0*/ __Vdly__speculative_decode_e2e_top__DOT__lc_busy;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v0;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v2;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v3;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v4;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v5;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v6;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v7;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v4;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v5;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v6;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_gate_r__v7;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v0;
        CData/*5:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__layer_idx_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v2;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v3;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v0;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v1;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v2;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v3;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v4;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v5;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v6;
    };
    struct {
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v7;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v8;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v9;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v10;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v11;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v12;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v13;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v14;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v15;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v16;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v17;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v18;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v19;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v20;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v21;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v22;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v23;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v24;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v25;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v26;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v27;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v28;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v29;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v30;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v31;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v32;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v33;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v34;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v35;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v36;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v37;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v38;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v39;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v40;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v41;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v42;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v43;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v44;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v45;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v46;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v47;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v48;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v49;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v50;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v51;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v52;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v53;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v54;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v55;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v56;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v57;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v58;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v59;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v60;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v61;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v62;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v63;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v64;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v65;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v66;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v67;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v68;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v69;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v70;
    };
    struct {
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v71;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v72;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v73;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v74;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v75;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v76;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v77;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v78;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v79;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v80;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v81;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v82;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v83;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v84;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v85;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v86;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v87;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v88;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v89;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v90;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v91;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v92;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v93;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v94;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v95;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v96;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v97;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v98;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v99;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v100;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v101;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v102;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v103;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v104;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v105;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v106;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v107;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v108;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v109;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v110;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v111;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v112;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v113;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v114;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v115;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v116;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v117;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v118;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v119;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v120;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v121;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v122;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v123;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v124;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v125;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v126;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v127;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v128;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_max_val_r__v8;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v129;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v4;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v5;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v6;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_norm_r__v7;
    };
    struct {
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v4;
        CData/*3:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__active_slots_r;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_mac_out_r__v132;
        CData/*0:0*/ __Vdlyvset__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__slot_hidden_r__v5;
        CData/*0:0*/ __Vclklast__TOP__clk;
        CData/*0:0*/ __Vclklast__TOP__rst_n;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_tree_builder__DOT____Vlvbound3;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound6;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound7;
        SData/*15:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound11;
        SData/*11:0*/ speculative_decode_e2e_top__DOT__u_dispatcher__DOT__u_tree_flatten__DOT____Vlvbound12;
        SData/*15:0*/ __Vfunc_speculative_decode_e2e_top__DOT__u_hht__DOT__context_hash__0__Vfuncout;
        SData/*15:0*/ __Vfunc_speculative_decode_e2e_top__DOT__u_hht__DOT__context_hash__0__older_token_i;
        SData/*15:0*/ __Vfunc_speculative_decode_e2e_top__DOT__u_hht__DOT__context_hash__0__newer_token_i;
        SData/*15:0*/ __Vdly__speculative_decode_e2e_top__DOT__seed_token_id_r;
        SData/*11:0*/ __Vdly__speculative_decode_e2e_top__DOT__seed_position_r;
        SData/*15:0*/ __Vdlyvval__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v0;
        SData/*15:0*/ __Vdlyvval__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v1;
        SData/*15:0*/ __Vdlyvval__speculative_decode_e2e_top__DOT__u_hht__DOT__entry_prediction_r__v2;
        SData/*15:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_tree_builder__DOT__timeout_cnt_r;
        SData/*8:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__beat_cnt_r;
        SData/*8:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__resp_cnt_r;
        SData/*8:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_input_dim_r;
        IData/*22:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__mv_weight_base_r;
        WData/*2047:0*/ __Vdly__speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__gamma_r[64];
        QData/*63:0*/ __Vdly__speculative_decode_e2e_top__DOT__lc_out_token_id;
    };
    static CData/*2:0*/ __Vtable1_speculative_decode_e2e_top__DOT__u_dispatcher__DOT__state_next[64];
    
    // INTERNAL VARIABLES
    // Internals; generally not touched by application code
    Vspeculative_decode_e2e_top__Syms* __VlSymsp;  // Symbol table
    
    // CONSTRUCTORS
  private:
    VL_UNCOPYABLE(Vspeculative_decode_e2e_top);  ///< Copying not allowed
  public:
    /// Construct the model; called by application code
    /// The special name  may be used to make a wrapper with a
    /// single model invisible with respect to DPI scope names.
    Vspeculative_decode_e2e_top(const char* name = "TOP");
    /// Destroy the model; called (often implicitly) by application code
    ~Vspeculative_decode_e2e_top();
    
    // API METHODS
    /// Evaluate the model.  Application must call when inputs change.
    void eval();
    /// Simulation complete, run final blocks.  Application must call on completion.
    void final();
    
    // INTERNAL METHODS
  private:
    static void _eval_initial_loop(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
  public:
    void __Vconfigure(Vspeculative_decode_e2e_top__Syms* symsp, bool first);
    void __Vdpiimwrap_speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_residual__DOT__dpi_residual_add_TOP(const WData/*8191:0*/ vec_a_flat[256], const WData/*8191:0*/ vec_b_flat[256], const CData/*3:0*/ active_slots_in, WData/*8191:0*/(&  vec_out_flat)[256], const IData/*31:0*/ num_slots_in, const IData/*31:0*/ dim_in);
    void __Vdpiimwrap_speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_rmsnorm__DOT__dpi_rmsnorm_TOP(const WData/*8191:0*/ vec_in_flat[256], const WData/*2047:0*/ gamma_flat[64], const CData/*3:0*/ active_slots_in, WData/*8191:0*/(&  vec_out_flat)[256], const IData/*31:0*/ num_slots_in, const IData/*31:0*/ dim_in);
    void __Vdpiimwrap_speculative_decode_e2e_top__DOT__u_layer_ctrl__DOT__u_silu_mul__DOT__dpi_silu_mul_TOP(const WData/*16383:0*/ vec_gate_flat[512], const WData/*16383:0*/ vec_up_flat[512], const CData/*3:0*/ active_slots_in, WData/*16383:0*/(&  vec_out_flat)[512], const IData/*31:0*/ num_slots_in, const IData/*31:0*/ dim_in);
  private:
    static QData _change_request(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
  public:
    static void _combo__TOP__4(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
  private:
    void _ctor_var_reset() VL_ATTR_COLD;
  public:
    static void _eval(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
  private:
#ifdef VL_DEBUG
    void _eval_debug_assertions();
#endif  // VL_DEBUG
  public:
    static void _eval_initial(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp) VL_ATTR_COLD;
    static void _eval_settle(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp) VL_ATTR_COLD;
    static void _sequent__TOP__1(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    static void _sequent__TOP__2(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp);
    static void _settle__TOP__3(Vspeculative_decode_e2e_top__Syms* __restrict vlSymsp) VL_ATTR_COLD;
} VL_ATTR_ALIGNED(VL_CACHE_LINE_BYTES);

//----------


#endif  // guard
