# `transformer_my` 第二阶段 testbench 工作区

本目录是第二阶段 `LLM decoder-only Transformer` 算子与层次化 bring-up 的正式
testbench 入口。

## 使用规则

1. 新的 operator 级 testbench 固定新建在本目录下。
2. 本目录服务于 `code/rtl/transformer_my/` 的正式工作集，不再沿用旧
   `ann_my` 命名作为第二阶段新增 testbench 的根目录。
3. 旧 `ann_my/legacy_cnn/` 样例只保留历史参考作用，不作为本目录的替代入口。
4. 当前建议优先新增的 testbench 包括：
   - `tb_transform_unit_1x1.v`
   - `tb_transform_layer_single_1x1.v`
   - `tb_transform_layer_multi_1x1.v`
   - `tb_attention_softmax_path.v`
