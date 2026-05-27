# 旧位置迁移说明

本目录不再作为第二阶段正式验证归档根目录。

## 当前约定

1. 第一阶段及既有基线 `run_001` 到 `run_057` 继续保留在旧的
   `code/tb/tree_control_tb/verification/` 体系下。
2. 第二阶段正式验证内容已经迁移到仓库根目录 `verification/stage2/`。
3. 第二阶段第一条 run 固定为
   `verification/stage2/01_vcs_control_chip_stage2_min_bringup/`。
4. PASS/FAIL 判断仍然只认 `summary`、`result`、`run.log`。

本目录现在只保留迁移提示，不再新增第二阶段 run。
