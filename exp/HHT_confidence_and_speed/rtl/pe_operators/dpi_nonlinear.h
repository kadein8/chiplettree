// dpi_nonlinear.h — DPI-C function declarations for Verilator
#ifndef DPI_NONLINEAR_H
#define DPI_NONLINEAR_H

#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

void dpi_rmsnorm(
    const svBitVecVal* vec_in,
    const svBitVecVal* gamma,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
);

void dpi_silu_mul(
    const svBitVecVal* vec_gate,
    const svBitVecVal* vec_up,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
);

void dpi_residual_add(
    const svBitVecVal* vec_a,
    const svBitVecVal* vec_b,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
);

#ifdef __cplusplus
}
#endif

#endif // DPI_NONLINEAR_H
