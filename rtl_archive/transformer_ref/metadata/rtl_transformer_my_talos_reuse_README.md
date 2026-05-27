# `talos_reuse` 工作集说明

本目录存放从 `code/TALOS-V2-main` 中筛出的第二阶段可复用或轻改复用 RTL。

## 当前纳入文件

1. `systolic_matvec16_tile.sv`
2. `processing_element.sv`
3. `matrixmul_unit.sv`
4. `rms_scale_engine.sv`
5. `sat_div16_engine.sv`
6. `microgpt_categorical_sampler.sv`
7. `include/microgpt_exact_core_math.svh`
8. `include/microgpt_exact_core_params.svh`

## 没有纳入的文件

1. `microgpt_exact_core.sv`
2. `de1_soc_microgpt_rtl.sv`
3. `sys_pll_56_25.v`
4. `include/microgpt_exact_core_rom_init.svh`

## 原因

1. 避免把内置 `k_cache/v_cache`、ROM 权重和单序列整核状态机直接固化进当前主链。
2. 避免把板级顶层、PLL 和 `readmemh` 初始化机制带入 stage2 正式工作集。
3. 当前只收引擎级、阵列级、数值级文件，不收整机级文件。
