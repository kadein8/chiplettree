// Verilated -*- C++ -*-
// DESCRIPTION: Verilator output: Prototypes for DPI import and export functions.
//
// Verilator includes this file in all generated .cpp files that use DPI functions.
// Manually include this file where DPI .c import functions are declared to ensure
// the C functions match the expectations of the DPI imports.

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif
    
    
    // DPI IMPORTS
    // DPI import at ../rtl/../rtl/pe_operators/pe_residual_add_compute.v:30
    extern void dpi_residual_add(const svBitVecVal* vec_a_flat, const svBitVecVal* vec_b_flat, const svBitVecVal* active_slots_in, svBitVecVal* vec_out_flat, int num_slots_in, int dim_in);
    // DPI import at ../rtl/../rtl/pe_operators/pe_rmsnorm_compute.v:31
    extern void dpi_rmsnorm(const svBitVecVal* vec_in_flat, const svBitVecVal* gamma_flat, const svBitVecVal* active_slots_in, svBitVecVal* vec_out_flat, int num_slots_in, int dim_in);
    // DPI import at ../rtl/../rtl/pe_operators/pe_silu_mul_compute.v:30
    extern void dpi_silu_mul(const svBitVecVal* vec_gate_flat, const svBitVecVal* vec_up_flat, const svBitVecVal* active_slots_in, svBitVecVal* vec_out_flat, int num_slots_in, int dim_in);
    
#ifdef __cplusplus
}
#endif
