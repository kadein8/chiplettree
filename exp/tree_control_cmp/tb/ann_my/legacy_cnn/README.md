# `ann_my/legacy_cnn` 旧样例 testbench 说明

本目录存放已经从第二阶段正式 testbench 工作区移出的旧 CNN/ANN 样例文件。

## 当前归档文件

1. `top_tb.v`
2. `ann_my.f`

## 使用规则

1. 这些文件只作为历史样例保留。
2. 它们不再作为第二阶段 `LLM decoder-only Transformer` 的正式验证入口。
3. 后续新的 operator 级 testbench 应直接新建在 `code/tb/transformer/` 根下。
