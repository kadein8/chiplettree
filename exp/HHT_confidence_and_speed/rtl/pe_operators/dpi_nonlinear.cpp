// dpi_nonlinear.cpp — DPI-C implementations of nonlinear FP16 operations
// Used by Verilator (which doesn't support 'real' type)
// VCS uses behavioral 'real' code instead.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "svdpi.h"

// FP16 to float conversion
static float fp16_to_float(uint16_t h) {
    uint32_t sign = (h >> 15) & 1;
    uint32_t exp  = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x3FF;
    if (exp == 0 && mant == 0) return 0.0f;
    if (exp == 0x1F) return sign ? -65504.0f : 65504.0f;
    float m = 1.0f + (float)mant / 1024.0f;
    float val = m * powf(2.0f, (float)exp - 15.0f);
    return sign ? -val : val;
}

static uint16_t float_to_fp16(float val) {
    if (val == 0.0f) return 0x0000;
    uint16_t sign = (val < 0.0f) ? 1 : 0;
    float a = sign ? -val : val;
    if (a >= 65504.0f) return (sign << 15) | (0x1E << 10) | 0x3FF;
    int exp_int = 0;
    float mant = a;
    while (mant >= 2.0f) { mant /= 2.0f; exp_int++; }
    while (mant < 1.0f && exp_int > -14) { mant *= 2.0f; exp_int--; }
    uint16_t exp_bits = (uint16_t)(exp_int + 15);
    uint16_t mant_bits = (uint16_t)((mant - 1.0f) * 1024.0f);
    return (sign << 15) | (exp_bits << 10) | mant_bits;
}

// Helper: extract uint16 from packed svBitVecVal at element index
static uint16_t get_fp16(const svBitVecVal* vec, int idx) {
    int bit_offset = idx * 16;
    int word_idx = bit_offset / 32;
    int bit_in_word = bit_offset % 32;
    uint32_t val = vec[word_idx] >> bit_in_word;
    if (bit_in_word > 16) {
        val |= vec[word_idx + 1] << (32 - bit_in_word);
    }
    return (uint16_t)(val & 0xFFFF);
}

// Helper: set uint16 in packed svBitVecVal at element index
static void set_fp16(svBitVecVal* vec, int idx, uint16_t val) {
    int bit_offset = idx * 16;
    int word_idx = bit_offset / 32;
    int bit_in_word = bit_offset % 32;
    uint32_t mask = 0xFFFF << bit_in_word;
    vec[word_idx] = (vec[word_idx] & ~mask) | ((uint32_t)val << bit_in_word);
    if (bit_in_word > 16) {
        uint32_t mask2 = 0xFFFF >> (32 - bit_in_word);
        vec[word_idx + 1] = (vec[word_idx + 1] & ~mask2) | ((uint32_t)val >> (32 - bit_in_word));
    }
}

extern "C" {

// DPI: RMSNorm
void dpi_rmsnorm(
    const svBitVecVal* vec_in,
    const svBitVecVal* gamma,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
) {
    for (int s = 0; s < num_slots; s++) {
        int slot_word = s / 32;
        int slot_bit = s % 32;
        if (!((active_slots[slot_word] >> slot_bit) & 1)) continue;

        double sum_sq = 0.0;
        for (int i = 0; i < dim; i++) {
            float x = fp16_to_float(get_fp16(vec_in, s * dim + i));
            sum_sq += (double)x * (double)x;
        }
        double inv_rms = 1.0 / sqrt(sum_sq / 1024.0 + 1e-6);

        for (int i = 0; i < dim; i++) {
            float x = fp16_to_float(get_fp16(vec_in, s * dim + i));
            float g = fp16_to_float(get_fp16(gamma, i));
            float out = (float)((double)x * inv_rms * (double)g);
            set_fp16(vec_out, s * dim + i, float_to_fp16(out));
        }
    }
}

// DPI: SiLU(gate) * up
void dpi_silu_mul(
    const svBitVecVal* vec_gate,
    const svBitVecVal* vec_up,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
) {
    for (int s = 0; s < num_slots; s++) {
        int slot_word = s / 32;
        int slot_bit = s % 32;
        if (!((active_slots[slot_word] >> slot_bit) & 1)) continue;

        for (int i = 0; i < dim; i++) {
            float g = fp16_to_float(get_fp16(vec_gate, s * dim + i));
            float u = fp16_to_float(get_fp16(vec_up, s * dim + i));
            float sig = 1.0f / (1.0f + expf(-g));
            float out = g * sig * u;
            set_fp16(vec_out, s * dim + i, float_to_fp16(out));
        }
    }
}

// DPI: Residual add
void dpi_residual_add(
    const svBitVecVal* vec_a,
    const svBitVecVal* vec_b,
    const svBitVecVal* active_slots,
    svBitVecVal* vec_out,
    int num_slots,
    int dim
) {
    for (int s = 0; s < num_slots; s++) {
        int slot_word = s / 32;
        int slot_bit = s % 32;
        if (!((active_slots[slot_word] >> slot_bit) & 1)) continue;

        for (int i = 0; i < dim; i++) {
            float a = fp16_to_float(get_fp16(vec_a, s * dim + i));
            float b = fp16_to_float(get_fp16(vec_b, s * dim + i));
            set_fp16(vec_out, s * dim + i, float_to_fp16(a + b));
        }
    }
}

} // extern "C"
