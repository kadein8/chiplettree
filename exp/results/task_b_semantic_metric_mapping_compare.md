# 实验B：论文语义到硬指标的最小映射证据

本实验不伪造缺失事件，而是先用 `18_` 与 `19_` 的正式 PASS 样本建立“论文语义 -> 可量化指标”的最小证据表。当前第一版主要落到`accepted_tokens / 槽位数 / 仿真结束时间(ps)` 三类硬指标，后续若补跑事件样本，可再继续细化到 `event_counts / hbm_write / cycle-to-wb_done`。

## 指标含义

- `accepted_tokens`: 最终闭环到写回的 token 数，体现该语义是否转化为真实完成工作。
- `窗口槽位数`: 窗口中可被正式消费的 branch 数，体现 multibranch/HHT 是否真的进入后端。
- `仿真结束时间(ps)`: bounded run 的粗粒度工作量指标，时间越长通常意味着后端路径更复杂。

## 数据对比

| 论文语义 | 样本run | accepted_tokens | 窗口槽位数 | 仿真结束时间(ps) | 直观结论 |
| --- | --- | --- | --- | --- | --- |
| multibranch | 19_strongest_bounded_window_hht_feedback | 4 | 4 | 2436000 | 同一窗口内多个槽位进入后端并闭环到写回 |
| partial/full | 19_strongest_bounded_window_hht_feedback | 4 | 4 | 2436000 | 同一 token 存在分阶段供数与补齐语义 |
| reuse | 19_strongest_bounded_window_hht_feedback | 4 | 4 | 2436000 | 后续 token 复用已有 full_ready 结果，避免重复路径 |
| HHT | 19_strongest_bounded_window_hht_feedback | 4 | 4 | 2436000 | HHT 命中与顶层写回反馈进入同一 bounded run |
