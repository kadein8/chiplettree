// tb_speculative_decode_e2e_verilator.cpp
// C++ testbench wrapper for Verilator simulation.
// Drives clock, reset, and stimulus for speculative_decode_e2e_top.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "Vspeculative_decode_e2e_top.h"
#include "verilated.h"

#define MAX_CYCLES 5000000
#define NUM_GEN_TOKENS 4
#define MEM_DEPTH 262144
#define HBM_DEPTH 131072

// Memory models
static uint32_t sram_mem[MEM_DEPTH][4]; // 128-bit = 4x32-bit
static uint32_t hbm_mem[HBM_DEPTH][8]; // 256-bit = 8x32-bit

// SRAM read pipeline
static int sram_rd_pending = 0;
static uint32_t sram_rd_addr_pending = 0;

// HBM read pipeline (2-cycle)
static int hbm_rd_pending = 0;
static uint32_t hbm_rd_addr_pending = 0;
static int hbm_stage2 = 0;
static uint32_t hbm_data_stage2[8];

static void load_memh_128(const char* path, uint32_t mem[][4], int depth) {
    FILE* f = fopen(path, "r");
    if (!f) { printf("ERROR: Cannot open %s\n", path); return; }
    char line[256];
    int addr = 0;
    while (fgets(line, sizeof(line), f) && addr < depth) {
        // Each line is 32 hex chars (128 bits)
        // Parse as 4x 32-bit words (MSB first in file)
        if (strlen(line) >= 32) {
            for (int w = 0; w < 4; w++) {
                char word[9];
                strncpy(word, line + w*8, 8);
                word[8] = 0;
                mem[addr][3-w] = (uint32_t)strtoul(word, NULL, 16);
            }
        }
        addr++;
    }
    fclose(f);
    printf("Loaded %d lines from %s\n", addr, path);
}

static void load_memh_256(const char* path, uint32_t mem[][8], int depth) {
    FILE* f = fopen(path, "r");
    if (!f) { printf("ERROR: Cannot open %s\n", path); return; }
    char line[512];
    int addr = 0;
    while (fgets(line, sizeof(line), f) && addr < depth) {
        if (strlen(line) >= 64) {
            for (int w = 0; w < 8; w++) {
                char word[9];
                strncpy(word, line + w*8, 8);
                word[8] = 0;
                mem[addr][7-w] = (uint32_t)strtoul(word, NULL, 16);
            }
        }
        addr++;
    }
    fclose(f);
    printf("Loaded %d lines from %s\n", addr, path);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vspeculative_decode_e2e_top* dut = new Vspeculative_decode_e2e_top;

    // Load memories
    memset(sram_mem, 0, sizeof(sram_mem));
    memset(hbm_mem, 0, sizeof(hbm_mem));
    load_memh_128("generated/sram_preload.memh", sram_mem, MEM_DEPTH);
    load_memh_256("generated/hbm_weights.memh", hbm_mem, HBM_DEPTH);

    // Preload HBM weights into SRAM at weight_sram_base (16384)
    // Each HBM beat (256-bit) = 2 SRAM beats (128-bit)
    {
        const uint32_t WEIGHT_SRAM_BASE = 16384;
        const uint32_t HBM_WEIGHT_BASE = 1024;
        int hbm_lines = 31776; // from file
        for (int h = 0; h < hbm_lines && h < HBM_DEPTH; h++) {
            uint32_t sram_addr = WEIGHT_SRAM_BASE + (h - 0) * 2;
            // Low 128 bits → first SRAM beat
            if (sram_addr < MEM_DEPTH) {
                for (int w = 0; w < 4; w++)
                    sram_mem[sram_addr][w] = hbm_mem[HBM_WEIGHT_BASE + h][w];
            }
            // High 128 bits → second SRAM beat
            if (sram_addr + 1 < MEM_DEPTH) {
                for (int w = 0; w < 4; w++)
                    sram_mem[sram_addr + 1][w] = hbm_mem[HBM_WEIGHT_BASE + h][w + 4];
            }
        }
        printf("Preloaded HBM weights to SRAM at %d\n", WEIGHT_SRAM_BASE);
    }

    // Reset
    dut->clk = 0;
    dut->rst_n = 0;
    dut->start = 0;
    dut->prompt_token_id = 0;
    dut->max_gen_tokens = NUM_GEN_TOKENS;
    dut->sram_rd_ready = 1;
    dut->sram_resp_valid = 0;
    dut->sram_wr_ready = 1;
    dut->hbm_rd_ready = 1;
    dut->hbm_resp_valid = 0;

    for (int i = 0; i < 10; i++) {
        dut->clk = !dut->clk;
        dut->eval();
    }
    dut->rst_n = 1;
    for (int i = 0; i < 4; i++) {
        dut->clk = !dut->clk;
        dut->eval();
    }

    // Start
    dut->start = 1;
    dut->clk = !dut->clk; dut->eval();
    dut->clk = !dut->clk; dut->eval();
    dut->start = 0;

    // Run simulation
    int token_count = 0;
    uint16_t tokens[64];
    int cycle = 0;

    while (!dut->done && cycle < MAX_CYCLES) {
        // Rising edge: set inputs based on previous cycle's outputs, then eval
        dut->clk = 1;

        // SRAM read model: respond to previous cycle's request
        dut->sram_resp_valid = 0;
        if (sram_rd_pending) {
            dut->sram_resp_valid = 1;
            uint32_t addr = sram_rd_addr_pending;
            if (addr < MEM_DEPTH) {
                for (int w = 0; w < 4; w++)
                    dut->sram_resp_data[w] = sram_mem[addr][w];
            } else {
                for (int w = 0; w < 4; w++)
                    dut->sram_resp_data[w] = 0;
            }
            sram_rd_pending = 0;
        }

        // HBM read model
        dut->hbm_resp_valid = 0;
        if (hbm_stage2) {
            dut->hbm_resp_valid = 1;
            for (int w = 0; w < 8; w++)
                dut->hbm_resp_data[w] = hbm_data_stage2[w];
            hbm_stage2 = 0;
        }
        if (hbm_rd_pending) {
            uint32_t addr = hbm_rd_addr_pending;
            if (addr < HBM_DEPTH) {
                for (int w = 0; w < 8; w++)
                    hbm_data_stage2[w] = hbm_mem[addr][w];
            } else {
                for (int w = 0; w < 8; w++)
                    hbm_data_stage2[w] = 0;
            }
            hbm_stage2 = 1;
            hbm_rd_pending = 0;
        }

        dut->eval();

        // Capture DUT outputs after eval (on rising edge)
        if (dut->sram_rd_valid) {
            sram_rd_pending = 1;
            sram_rd_addr_pending = dut->sram_rd_addr;
        }
        if (dut->sram_wr_valid) {
            uint32_t addr = dut->sram_wr_addr;
            if (addr < MEM_DEPTH) {
                for (int w = 0; w < 4; w++)
                    sram_mem[addr][w] = dut->sram_wr_data[w];
            }
        }
        if (dut->hbm_rd_valid) {
            hbm_rd_pending = 1;
            hbm_rd_addr_pending = dut->hbm_rd_addr;
        }
        if (dut->token_out_valid) {
            tokens[token_count] = dut->token_out_id;
            printf("  Token[%d] = %d (cycle %d)\n",
                   token_count, dut->token_out_id, cycle);
            token_count++;
        }

        // Falling edge
        dut->clk = 0;
        dut->eval();

        cycle++;
        if (cycle % 100000 == 0)
            printf("  [debug] cycle=%d busy=%d sram_rd=%d sram_resp=%d addr=0x%x\n",
                   cycle, dut->busy, dut->sram_rd_valid, dut->sram_resp_valid, dut->sram_rd_addr);
        if (cycle == 20 || cycle == 30 || cycle == 40 || cycle == 100 || cycle == 200 || cycle == 500)
            printf("  [debug@%d] busy=%d sram_rd=%d addr=0x%x resp=%d\n",
                   cycle, dut->busy, dut->sram_rd_valid, dut->sram_rd_addr, dut->sram_resp_valid);
    }

    if (!dut->done) {
        printf("ERROR: Timeout after %d cycles\n", MAX_CYCLES);
    }

    printf("\n=== Speculative Decode Complete ===\n");
    printf("Total tokens: %d, Cycles: %d\n", token_count, cycle);

    // Write output
    FILE* fout = fopen("rtl_output_tokens.txt", "w");
    for (int i = 0; i < token_count; i++)
        fprintf(fout, "%d\n", tokens[i]);
    fclose(fout);

    printf("tb_speculative_decode_e2e PASS\n");
    delete dut;
    return 0;
}
