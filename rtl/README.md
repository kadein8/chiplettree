# RTL 工作区

本目录是第二阶段 RTL 工作区。

已验证来源工作区仍然是 `code/rtl_ori/`。当前可以正式引用的最新基线仍然是
`run_057_vcs_chiplet_top_tree_driven_reusable_idle_final_closure` 对
`tree_control/control_chip` 路径的 bounded、tree-driven、strict-serial /
reusable-idle 单芯粒闭环证明，不能夸大成 full chiplet closure，也不能夸大成
unbounded proof。

## 目录结构

- `config/`
  - 从 `rtl_ori/config` 复制来的共享参数与接口头文件
- `tree_control/`
  - 第二阶段单芯粒 control / memory 路径工作副本
- `transformer/`
  - 第二阶段 `LLM decoder-only Transformer` 正式 RTL 工作区
  - 根目录只保留正式参与实现/编译的 `.v/.sv`
  - 最多只保留 `include/` 作为头文件次一级目录
- `..\rtl_archive\transformer_ref\`
  - 第二阶段 Transformer 参考 RTL 归档区
  - 存放旧 CNN、ViT、LeViT、TALOS 整核、模板与不可直接编译资产

## 当前规则

1. `rtl_ori/` 继续作为已验证来源工作区，不直接覆盖。
2. 第二阶段 RTL 只在 `code/rtl/` 下推进。
3. `tree_control/` 必须保持已验证 ownership split 与 no-shortcut 边界。
4. `transformer/` 正式工作集只保留 `LLM decoder-only Transformer` 可复用或可改造模块。
5. 正式 Transformer 工作区内不再保留 `primitive/`、`talos_reuse/`、`reference_only/`、`legacy_cnn/` 这类功能分层子目录。
6. 第二阶段正式主链不是 `ViT`、不是 `LeViT`、不是 image transformer。
7. 多头注意力允许基于 `grouped-conv` 或 `grouped 1x1 projection` 实现，但接口语义必须是
   `token / vector / KV`。
8. 第二阶段单芯粒整合命名继续仿照旧 `ann_my` 的“顶层 + Integration*Part + 基础模块”层次，但正式工作目录固定为 `transformer`。
9. 旧参考 RTL 统一归档到 `code/rtl_archive/transformer_ref/`，不得直接作为 stage2 正式验证链路的一部分。
10. 第二阶段 Transformer testbench 根目录固定为 `code/tb/transformer/`。
11. 第二阶段 Transformer 参考向量根目录固定为 `code/weight/transformer/`。
12. 第二阶段正式文档根目录是 `docs/stage2/`。
13. 第二阶段验证归档根目录是 `verification/stage2/`。

