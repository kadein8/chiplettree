# 第二阶段 Transformer 参考向量目录

本目录预留给第二阶段 `LLM decoder-only Transformer` bring-up 过程中的参考向量、假权重、KV 样例和输入输出模板。

## 使用规则

1. `code/weight/` 根目录里的旧文件仍然视为历史 CNN/ANN 样例，不得误写成第二阶段正式模型参数。
2. 第二阶段新增的参考向量、假权重和格式模板固定放在本目录下。
3. 若后续引入 fake SRAM、fake HBM、fake draft 的参考数据，也应优先在本目录按功能分组。
4. 当前阶段不在本目录固化真实厂商 SRAM macro 内容，也不固化真实 HBM 控制器私有格式。

