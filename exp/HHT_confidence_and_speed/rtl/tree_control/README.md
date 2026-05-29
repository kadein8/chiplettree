# Tree Control 第二阶段工作副本

本目录是 `code/rtl_ori/tree_control/` 的第二阶段工作副本。

## 当前文件

- `control_chip.v`
- `IntegrationPredictionPart.v`
- `tree_analyze.v`
- `agu.v`
- `prefetch_queue.v`
- `free_list.v`
- `bank_state_table.v`
- `token_register.v`
- `request_controller.v`
- `sram_subsystem.v`
- `sram_bank.v`
- `sram_subbank.v`
- `comparator.v`
- `prediction_unit_bounded_stub.v`
- `compute_module_bounded_stub.v`
- `commit_writeback_bounded_shim.v`
- `IntegrationTreeControlPart.v`
- `IntegrationOperatorPart.v`
- `IntegrationWritebackPart.v`
- `KVLocationTable.v`
- `KVStateTable.v`
- `RecomputeControl.v`
- `control_chip_stage2_single_chiplet.v`

## 必须冻结的边界

1. `AGU -> prefetch_queue -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE/Compute -> request_controller -> SRAM -> PE response`
5. 不允许 shortcut wiring
6. 不允许把 `request_controller` 当成 `token_register lookup` 的直接下游
7. 不允许 `bank_state_table -> token_register`
8. 不允许 SRAM internal flush
9. 若按论文回流视角画图，必须写成
   `SRAM -> request_controller(resp regroup) -> multicast_network -> PE arrays`
10. 第 9 条只是响应回流位置说明，不改变第 4 条 ownership split
11. strict 后端还必须显式保留 transformer 算子链层次：
   `compute descriptor -> transformer operator chain
   (embedding / decoder-layer stack / final norm + lm head)
   -> readout/comparator`

## 第二阶段结构说明

第二阶段单芯粒整条链路不再使用 `model_runtime_wrapper`、
`compute_cluster_wrapper` 这类命名，而是仿照 `ann_my` 的层次写法：

1. `control_chip`
2. `IntegrationPredictionPart`
3. `IntegrationTreeControlPart`
4. `IntegrationTransformPart`
5. `IntegrationWritebackPart`
6. 下层基础模块和算子模块

说明：

1. `IntegrationTransformPart` 位于 `code/rtl/transformer/`。
2. `IntegrationOperatorPart.v` 当前仍不是第二阶段最终主层命名，但它已经不再是全零桩模块。
3. 当前 `IntegrationOperatorPart.v` 已作为真实 operator 过渡适配层，
   内部直接复用 `IntegrationTransformPart` 完成
   `issue -> op_req -> op_resp -> result` 闭环。
4. 当前新增的 `Integration*Part` 文件先作为结构骨架存在，不在这一轮改写
   已验证控制逻辑行为。
5. `KVLocationTable.v`、`KVStateTable.v`、`RecomputeControl.v` 负责第二阶段
   的最小 KV 位置/状态管理与 `stale -> recompute -> partial/full-KV` 前置控制。
6. 从第二阶段 `08_` 开始，`KVLocationTable / KVStateTable` 的正式 key 语义冻结为
   `(referenced_token_id, referenced_position)`，不是
   `(current_candidate_token_id, referenced_position)`。
7. `RecomputeControl.v` 对外发出 `recompute_req_token_id` 时仍携带当前 candidate token，
   但写回 KV 表时必须使用 `start_referenced_token_id`。
8. 第二阶段 compute 目标固定为单芯粒 `LLM decoder-only Transformer`，不是
   `ViT`、不是 `LeViT`、不是 image transformer。
9. tree-control 侧对外只承载 `token / branch / metadata / KV ownership` 语义，不承载
   `image / pooling / receptive-field` 语义。
10. 从第二阶段 `09_` 开始，`IntegrationPredictionPart.v` 新增参数化“多分支窗口模式”：
   - 默认关闭，保持 `01_~08_` 的单候选 `pred_*` 行为
   - 打开后允许同拍保留多个高置信候选
   - 新增 `tree_window_*` 显式 metadata 输出
   - 当前只准备证明 prediction 侧多分支输入树窗口生成，不等于完整 top closure
11. 从第二阶段 `11_` 开始，新增 `control_chip_stage2_single_chiplet.v`：
   - 不改写旧 `control_chip.v`
   - 只作为 stage2 单 chiplet bounded full-top bring-up 顶层
   - 内部正式装配 `IntegrationPredictionPart / IntegrationTreeControlPart / IntegrationTransformPart / IntegrationWritebackPart / request_controller / sram_subsystem`
   - 当前 `tree_window_*` 仍是 side-band 观测口，不表示 `tree_analyze/AGU` 已正式消费多分支窗口
12. 从第二阶段 `12_` 开始，新增“多路 admission 并入单 chiplet 总装”的正式验证口径：
   - `09_` 的多分支 `tree_window_*` 保留能力，与 `11_` 的 rank0 最小全链路在同一 run 合并验证
   - 这一步仍不表示 `tree_analyze/AGU` 已正式消费多分支窗口
   - 这一步仍不覆盖 `partial/full-KV + next-token 邻接复用` 的系统级整合
13. 从第二阶段 `13_` 开始，新增“partial/full-KV + next-token full_ready reuse 并入单 chiplet 总装”的正式验证口径：
   - 继续使用 `control_chip_stage2_single_chiplet.v` 作为正式总装顶层
   - 只覆盖 single-rank0、strict-serial 条件下的
     `partial-KV -> 当前 token 先完成 -> full-KV 补齐 -> 下一个 token full_ready 复用`
   - 当前不与 `12_` 的多路 admission 并发窗口总装 run 联合证明

补充说明：

1. `request_controller` 在论文语义里同时承担两件事：
   - 前向把 PE/compute 请求 merge/arbitrate 后送入 `sram_subsystem`
   - 回流把 SRAM 返回 beat 按保存的 `req_id/pe_mask` 重组，再送入 `multicast_network`
2. `multicast_network` 不直接面向 `token_register lookup`，也不直接拥有 SRAM 物理请求；
   它只消费 `request_controller` 重组后的响应。
3. 当前 strict paper backend 的正式算子链容器是
   `StrictTreeMaskPaperTransformerOperatorChain`：
   - `PaperPeArrays16x128Mesh` 承接 embedding / layer-stack 对应的 raw hidden tile
   - `StrictTreeMaskPaperLogitsPostprocess` 承接 final norm / lm head 对应的 formal logits tile
