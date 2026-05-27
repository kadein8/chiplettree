# Transformer 参考归档区

本目录统一存放第二阶段 Transformer 正式工作区之外的历史代码、结构参考和迁移元数据。

## 目录职责

1. `legacy_cnn/`
   - 存放旧 CNN / image 语义 RTL
2. `reference_only/`
   - 存放 ViT / LeViT / TPU 阵列等只作结构参考的外部 RTL
3. `metadata/`
   - 存放迁移阶段保留下来的旧 filelist、旧清单、历史 README 和阶段性元数据

## 使用规则

1. 本目录所有文件都不进入 `code/rtl/config/stage2_transformer_formal_workset.f`。
2. 本目录所有文件都不作为 `control_chip` 第二阶段正式编译输入。
3. 允许基于这些文件“参考后重写”，不允许直接把归档文件重新接回正式链路。
4. 与 `run_057` 相关的任何表述仍然只能写成 bounded、tree-driven、strict-serial / reusable-idle 单芯粒基线。
