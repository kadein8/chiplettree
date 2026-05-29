# code_by

本目录只保留已经从 `code/rtl/` 主工作区移出的遗留 bring-up 资产。

当前保留内容：
- `code/code_by/tb/`
  - 历史专用 RTL testbench 资产

当前不再放置：
- `transformer/`
  - 正式 Transformer / 算子链 / strict backend 相关工作集已经回到 `code/rtl/transformer/`

使用规则：
- 论文主链框架相关代码统一以 `code/rtl/` 为准。
- `code/code_by/` 不再作为正式 framework 源目录。
- 如果历史对照脚本仍依赖遗留 TB，只能显式引用 `code/code_by/tb/`，不能再把 framework 代码迁回这里。
