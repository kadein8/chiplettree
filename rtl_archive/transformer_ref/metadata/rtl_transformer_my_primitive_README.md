# `primitive` 工作集说明

本目录存放第二阶段 `transformer_my` 的基础原语与模板。

## 子目录

1. `fp16/`
   - 当前最直接可复用的 FP16 primitive
2. `fp32/`
   - 历史兼容与数值参考 primitive
3. `projection_templates/`
   - 用于派生 `transformUnit1x1` / `transformLayer*` 的结构模板
4. `numeric_templates/`
   - softmax / exponent / reciprocal 的旧数值模板

## 使用规则

1. `fp16/` 是最小 bring-up 的第一优先级。
2. `projection_templates/` 和 `numeric_templates/` 不直接宣称为“已适配 stage2 接口”的成品。
3. 后续新建的正式 Transformer 层次，应与这些模板并列放置，而不是回写到旧 CNN 文件里。
