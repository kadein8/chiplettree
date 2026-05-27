# `reference_only` 结构参考说明

本目录存放从外部 TPU / LeViT 工程中筛出的“结构参考文件”。

## 规则

1. 本目录不是 stage2 正式 filelist。
2. 本目录文件进入 `transformer_my` 的目的，是减少后续再次回源检索成本。
3. 正式接入时只能按当前项目语义重写，不能把这些文件直接当作成品模块接到主链。

## 子目录

1. `vit_fpga_tpu/`
   - 保留 `systolic_array` 一类阵列组织方式
   - `PE.sv` 仍保留 vendor 浮点包装依赖，只能看结构
2. `tiny_levit/`
   - 保留 `PE_MAC`、`PE_2D`、`PE_ROW*` 的阵列/流水组织方式
   - 不引入其 attention / top-level / tanh 路径
