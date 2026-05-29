# RTL Rule: 论文唯一主路径与执行约束

> 最后更新：2026-05-23  
> 适用范围：`code/rtl/` 下所有 strict tree-mask 相关 RTL 改造  
> 目的：把当前实现统一收敛到论文设计的唯一主路径，禁止回退到并行捷径路线

## 1. 本文件的地位

1. 本文件是当前 `code/rtl/` 改造的唯一规则文件。
2. 后续 strict tree-mask RTL 改造不得偏离本文件。
3. 如果仓库里旧文档、旧测试、旧实现与本文件冲突，以本文件和当前用户指令为准。
4. 如果出现新的架构分岔、语义歧义、实现边界不清，不允许自作主张，必须先停下并向用户确认。

## 2. strict tree-mask 唯一主路径

strict tree-mask 顶层唯一主路径固定为三段并行协同边界：

`tree_analyze -> agu -> free_list -> bank_state_table`

`tree_analyze -> agu -> token_register -> token_register lookup -> KV SRAM hierarchy`

`pe arrays issue -> request_controller -> sram_subsystem -> request_controller(resp regroup) -> multicast_network -> pe arrays -> readout/comparator`

说明：

1. `AGU -> free_list -> bank_state_table` 是 allocation/status 路径。
2. `AGU -> token_register -> token_register lookup -> KV SRAM hierarchy` 是 metadata/install + location lookup 路径。
3. `request_controller` 只服务 PE arrays / compute 侧访存，不是 `token_register lookup` 的直接下游。
4. 对 `request_controller` 的线性画法必须区分前后两半：
   - issue 侧：`PE/Compute -> request_controller -> SRAM`
   - return 侧：`SRAM -> request_controller(resp regroup) -> multicast_network -> PE arrays`
5. `readout/comparator` 消费的是 PE arrays 的正式数值结果，不是裸 SRAM 返回 beat。
6. 不存在 `free_list -> token_register`。
7. 不存在 `bank_state_table -> token_register`。
8. 不存在 `token_register lookup -> request_controller` 的 direct shortcut。
9. strict 计算后端必须显式保留 transformer 算子链层次：
   `compute descriptor -> transformer operator chain
   (embedding / decoder-layer stack / final norm + lm head)
   -> readout/comparator`
10. 不允许再把上述算子链层次压扁回单个旧 `fp16_inference_top` 主方案。

## 3. 已废弃主方案

下列路径不再允许作为 strict tree-mask 主方案：

1. `tree_verify_dispatcher -> batch fp16 inference`
2. `tree_flatten -> tree_mask -> batch_out`
3. `fp16_inference_top` 直连 strict tree-mask 顶层主入口
4. 任何“串行 prefix replay 重新成为 strict 主链”的退化实现

说明：

1. 上述模块可以暂时保留在仓库中作为遗留代码或独立调试资产。
2. 但它们不得再挂在 strict tree-mask 顶层正式主路径上。

## 4. TreeControl 前端并行语义

从 `tree_analyze` 往后，前后端都必须支持并行。

固定语义：

1. `tree_analyze` 输出 shared-prefix 与 layered-frontier 的正式树语义。
2. frontier 采用“整层 bundle”语义：
   - 一拍对应一个 tree level
   - 一拍内最多 `BRANCH_NUM` 个有效 slot
   - 所有 slot 保留 parent-child / sibling / shared-ancestor 关系
3. `AGU` 必须按 bundle 级并行消费，而不是单 pending 节点串行推进。
4. `free_list` / `bank_state_table` 必须支持多 branch 资源并行分配。
5. `token_register` 必须支持多 branch 元数据并行写入与并行 lookup。
6. 后端 `pe arrays` 必须支持多 branch / 多 slot 同拍推进，不再保留 seed 先算、draft 后算的主语义。

## 5. 2D PE Mesh 要求

计算后端固定采用 `2D PE mesh` 脉动阵列路线。

固定要求：

1. 允许仿照 `code/ref/TALOS-V2-main/rtl/src` 的 2D mesh 组织方式。
2. 不允许直接把参考工程原样复用成顶层主后端。
3. 新 PE mesh 必须适配当前仓库基础设施：
   - `FP16`
   - `req_id`
   - `pe_mask`
   - `request_controller`
   - `multicast_network`
   - `SRAM ready/valid`
4. 新后端必须成为 strict tree-mask 唯一正式计算入口。
5. 当前 `fp16_mha_tree_attention` 这种“seed 标量控制器 + draft 多 lane 复制块”的结构不再作为最终主方案。

## 5.1 参数化与模型无关要求

strict tree-mask 论文主链必须支持“只改基础参数/配置即可适配模型”的方向。

固定要求：

1. strict paper path 里的正式 compute descriptor、PE mesh、workspace 地址规划，不允许绑定单一模型名字。
2. 新实现不允许把 `TOY_*`、`QWEN3_*` 之类 profile 名字直接当作 strict paper path 的最终语义边界。
3. strict paper path 允许引用：
   - 通用模型参数名
   - 通用硬件参数名
   - 通用 layout/base-address 参数名
4. 目标必须是“只改基础参数/配置即可适配模型”，不能把某一个模型的隐含假设写死进 strict 主链。
5. 通用参数至少要覆盖：
   - `MODEL_DMODEL`
   - `MODEL_HEAD_DIM`
   - `MODEL_HEAD_NUM`
   - `MODEL_MAX_POS_EMB`
   - `PE_NUM`
   - `MAC_NUM_PER_PE`
   - `STRICT_PAPER_PE_ROWS`
   - `STRICT_PAPER_PE_COLS`
6. 如果某个 profile 目前只有 toy manifest 或某个真实模型权重包可用，也只能把它当成“当前默认配置来源”，不能当成 strict paper path 的唯一硬编码语义。
7. 任何新 RTL 若需要知道 base address、tile 数、workspace stride、K 维 sweep 次数，必须从参数/descriptor 推导，不能再靠“把 token/position/visible/state 杂糅相加”的占位地址公式；这类做法统一归类为禁止的“metadata 杂糅地址公式”。

说明：

1. 允许仓库继续保留 toy/qwen 等 profile 作为默认值或测试夹具。
2. 但 strict paper path 的正式边界必须先抽象成模型无关参数，再由默认 profile 去赋初值。

## 6. ownership split 硬边界

以下边界必须保持：

1. `AGU -> free_list -> bank_state_table`
2. `AGU -> token_register`
3. `token_register lookup -> SRAM`
4. `PE/Compute -> request_controller -> SRAM -> PE response`

以下行为禁止引入：

1. `bank_state_table -> token_register`
2. `request_controller` 成为 `token_register lookup` 的直接下游
3. `comparator -> token_register` direct shortcut
4. `comparator -> bank_state_table` direct shortcut
5. `SRAM internal flush`
6. 为了省事绕回 `tree_verify_dispatcher -> batch fp16 inference`
7. 为了赶进度，把 compute descriptor 退化回“若干 metadata 直接拼地址”的伪语义

## 7. flush 顺序语义

flush 必须严格遵守论文语义与顺序要求。

固定顺序：

1. `preflush barrier`
   - 先等待已经进入 compute / request / multicast / pe mesh 的在飞工作走到可退休边界
   - 不允许跳过 preflush 直接 flush
2. `AGU freeze`
   - comparator 判定出 flush 后，先冻结 `AGU`
   - 停止接受新的 prefix/frontier bundle
3. `allocation/status flush`
   - 路径固定为 `AGU/control -> free_list -> bank_state_table`
   - 串行 drain wrong subtree 的 reclaim
4. `metadata flush`
   - 路径固定为 `AGU/control -> token_register`
   - 使用同一份有序 victim 语义，不允许由 `bank_state_table` 直接驱动
5. `flush_done`
   - 只有 allocation/status 路与 metadata 路都 drain 完，才能宣布 flush 完成
6. `survivor reopen`
   - 只有在 `flush_done` 后，survivor 路径才能继续 issue / compare / commit

victim 顺序固定为：

1. 先 flush 更深层的 wrong descendants
2. 再 flush 更浅层的错误分叉点
3. full loser branches 先于 winner branch 的未接受 suffix
4. shared prefix 与已 committed 条目不能被当作 wrong private victim

如果后续实现中发现“深到浅”与论文文字描述存在歧义，不允许私自改顺序，必须先问用户。

## 8. 数值正确性优先级

后续验证优先级固定为：

1. 先看 `hidden`
2. 再看 `logits`
3. 最后才看 `token`

禁止错误判断：

1. 不能因为最终 token 偶然对了，就判定实现正确。
2. 不能拿 stale compare 工件替代当前真实 run 结论。
3. 不能在 runtime deadlock 未修通前，用旧 compare 结果下结论。

## 9. 实施顺序

实施顺序固定如下：

1. 先用测试和结构约束锁住论文唯一主路径
2. 新建 strict tree-mask 论文主路径容器模块
3. 从顶层断开 `tree_verify_dispatcher -> batch fp16 inference`
4. 把 `tree_analyze -> AGU` 改成整层/多 branch bundle 并行接口
5. 把 `AGU -> free_list -> bank_state_table` 改成并行 alloc/status 路
6. 把 `AGU -> token_register` 改成并行 metadata 路
7. 把 `paper_issue_bundle` 扩成正式、参数化、模型无关的 compute descriptor 边界
8. 引入新的 `pe issue scheduler`
9. 引入新的 `2D PE mesh`
10. 重写 comparator 的 longest-path / ordered-flush 语义
11. 最后做数值对齐与 host/vm 联调

## 10. 分岔处理规则

遇到以下情况，禁止自作主张：

1. flush 顺序出现两种以上合理解释
2. shared prefix / private branch 的物理映射策略存在多种可行实现
3. `2D PE mesh` 的 tile 规格、累加宽度、K 维推进方式存在多种候选
4. comparator 的 accepted-depth / bonus / subtree victim 顺序与论文文字可能存在偏差
5. 顶层是否保留某个旧模块作为调试资产，影响正式主路径边界

处理方式固定为：

1. 停止继续扩展实现
2. 报告当前证据、候选分叉点、每个候选的具体影响
3. 等待用户明确裁决

## 11. 执行纪律

1. 不做破坏性 git 操作。
2. 修改前先读证据，再改 RTL。
3. 每次给运行命令时，必须同时给：
   - 主机命令
   - VM 命令
   - 监视命令
4. 主机跑 Python / PowerShell，VM 跑 VCS bash。
5. 能写入日志的纠错，优先写到日志里。

## 12. 当前执行结论

从本文件生效起：

1. strict tree-mask 正式目标不再是“修当前 shortcut”。
2. 正式目标改为“直接实现论文唯一主路径的最终方案”。
3. 后续任何 RTL 变更都必须能回答：
   - 是否更接近本文件第 2 节的唯一主路径
   - 是否破坏了第 6 节的 ownership split
   - 是否违反了第 7 节的 flush 顺序
   - 是否在分岔点上擅自做了决定

## 13. 当前分岔状态

1. `StrictTreeMaskPaperPath` 的前半段收口分岔已经由用户裁决为 `B`
   - 含义：先完成并固定 `AGU` 的 `bundle` 并行接口，再继续把改写后的论文主路径收进 `StrictTreeMaskPaperPath`
   - 当前已落实：
     - `tree_analyze -> bundle -> AGU -> prefetch_queue -> free_list`
     - `free_list -> bank_state_table`
     - `AGU -> token_register`
     - `token_register -> issue bundle`
2. 从这一条裁决生效后：
   - 允许继续沿 `token_register -> token_register lookup -> KV SRAM hierarchy`
     与 `pe arrays issue -> request_controller -> sram_subsystem ->
     request_controller(resp regroup) -> multicast_network -> pe arrays ->
     readout/comparator` 收口
   - 不允许回退到 `tree_verify_dispatcher -> batch fp16 inference` 作为 strict 正式主链
3. 若后续进入新的目标分岔：
   - 必须先报告具体证据、候选边界和影响
   - 未经用户再次裁决，不允许擅自选择
4. `PaperPeArrays16x128Mesh` 的 `PE arrays` 组织方案已由用户裁决为“方案2”
   - 含义：采用完整 `4x4` wavefront / 2D systolic mesh 推进
   - 禁止退回“一个 slot 固定绑定一整行 PE、行内直接归约”的方案1
   - 后续数值核实现必须继续沿 wavefront phase / mesh cell ownership 收紧
5. strict paper path 的参数化方向已冻结
   - 含义：后续 descriptor / mesh / layout 只能往“基础参数可配置、默认 profile 可替换”的方向推进
   - 禁止把 toy profile、某个具体模型 profile 写死成 strict 主链唯一实现
6. strict backend 的正式结果边界已由用户裁决为“方案2”
   - 含义：PE arrays / mesh backend 先输出 hidden/logits tile
   - token comparator 必须放到更外层 readout 之后
   - 禁止 `PaperPeArrays16x128Mesh` 继续直接输出 `result_accept`
   - 禁止把 `mesh backend` 的正式结果边界退回成“直接吐最终 token/accept”的方案1

## 14. RTL 目录保留口径

1. 当前 `code/rtl/` 只保留论文主链直接相关目录与文件：
   - `config/`
   - `transformer/`
   - `tree_control/`
   - `README.md`
   - `rule.md`
2. 已迁出的遗留 RTL / 专用 TB 统一放到 `code/code_by/`：
   - `code/code_by/tb/`
3. `transformer/` 正式工作集必须放在 `code/rtl/transformer/`，不得再作为 `code/code_by/` 的外置遗留目录保留。
4. 旧 bring-up / 对照脚本如果仍需要遗留 TB，只允许通过显式文件列表或 `+incdir` 引到 `code/code_by/`，不允许把 framework 代码重新迁出 `code/rtl/`。
