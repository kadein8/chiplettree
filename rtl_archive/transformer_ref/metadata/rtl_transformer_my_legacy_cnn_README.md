# `legacy_cnn` 旧 CNN 资产说明

本目录存放已经从第二阶段 `transformer_my` 正式主目录移出的旧 CNN / image 语义文件。

## 放入本目录的原则

1. 文件体仍绑定 `image / receptive-field / pooling / tanh-wrapper` 等旧语义。
2. 文件不再作为第二阶段 `LLM decoder-only Transformer` 正式主链的直接编译输入。
3. 文件可以保留作“复制后重写”的历史参考，但不能直接带回正式主目录。

## 当前归档文件

1. `convLayerSingle.v`
2. `convLayerMulti.v`
3. `RFselector.v`
4. `AvgUnit.v`
5. `AvgPoolSingle.v`
6. `AvgPoolMulti.v`
7. `activationFunction.v`
8. `HyperBolicTangent.v`
9. `HyperBolicTangent16.v`
10. `UsingTheTanh.v`
11. `UsingTheTanh16.v`
