# `transformer_my/config` 说明

本目录预留给第二阶段 Transformer 侧的局部参数头文件、filelist 片段和 bring-up 配置。

当前规则：

1. `code/rtl/config/` 仍是共享参数与接口头文件的权威位置。
2. `transformer_my/config/` 不复制板级、vendor 或 tree-control 专属配置。
3. 只有当 Transformer 侧出现独立参数边界时，才在本目录新增头文件。

## 当前文件

1. `stage2_transformer_my_formal_workset.f`
   - 第二阶段 `transformer_my` 正式工作集 filelist
   - 只纳入 `primitive/` 与 `talos_reuse/`
2. `stage2_transformer_my_reference_manifest.txt`
   - `reference_only/` 文件清单
   - 只作结构参考，不进入默认编译
3. `stage2_transformer_my_legacy_manifest.txt`
   - `legacy_cnn/` 文件清单
   - 只作历史参考，不进入默认编译
