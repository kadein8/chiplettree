# 配置与 filelist

本目录存放第二阶段单芯粒项目共享头文件，以及正式 Transformer 工作集 filelist。

## 规则

1. 共享宏、参数头文件统一放在这里，不要把同一常量散落复制到多个 RTL 文件。
2. 需要冻结的值、临时占位值，要在注释和文档中明确区分。
3. 正式 Transformer filelist 只能指向 `code/rtl/transformer/` 和 `code/rtl/transformer/include/`。
4. 不要把参考归档区或迁移前旧路径重新写回正式 filelist。

## 当前文件

1. `memory_params.vh`
2. `model_params.vh`
3. `prediction_params.vh`
4. `interface_params.vh`
5. `stage2_transformer_formal_workset.f`

## 使用说明

1. 头文件按需 `include`，不要无差别全量引入。
2. 模块优先通过参数和显式端口暴露配置，不要依赖隐藏 magic number。
3. `stage2_transformer_formal_workset.f` 只代表第二阶段 Transformer 正式工作集，不代表 tree-control 或参考归档区。
4. 当配置或 filelist 变化时，要同步更新 `docs/stage2/` 的中文文档。
