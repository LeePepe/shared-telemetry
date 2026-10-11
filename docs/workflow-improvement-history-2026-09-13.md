# Workflow 改进：历史报告与资料索引

整理日期：2026-09-13。配合 [当前交接报告](workflow-improvement-handoff-2026-09-13.md) 使用。

这里保留原文件，不复制/覆盖历史报告，也不将旧状态当作今天的事实。以下链接均为本机文件；下一 session 若换机器，需先核实文件位置。

## 建议阅读顺序

1. 当前交接报告：定位 MY-1555、日志查询和暂停边界。
2. 8/30 Owner v3：了解跨项目反复与责任缺口。
3. 9/5 增量报告及补充：了解恢复权限、quarantine 和工具越权问题。
4. 防停滞方案：抽取稳定身份/实质推进/等待责任/持久预算，重新对齐 native autopilot 决策。
5. 当前 skill、authority、autopilot 合同及旧 recovery plan：统一事实源，标记失效步骤。

## 2026-08-30：VitalStride + AIDash 基线

| 文件 | 用途 / 已读出的历史结论 |
|---|---|
| [Owner 报告 v3](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/report-owner-v3-20260830T010004Z.md) | 当时 40 案例，交付可信18/不可信0/未知22；实际效果确认解决0。重点为角色高重复、3个无下一负责人任务、早期权限越界和 required gate 自举死锁。数值只属于当时 cohort。 |
| [完整技术报告：完成性重跑](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/report-rerun-20260830T010004Z.md) | 案例表、角色重复指标、instruction observations 和技术证据；优先于初版作为同次分析的补充。 |
| [初版技术报告](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/report.md) | 保留初次分析轨迹，不与重跑版重复计数。 |
| [Owner v1](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/report-owner-20260830T010004Z.md) / [Owner v2](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/report-owner-v2-20260830T010004Z.md) | 展示格式的历史版本；阅读优先使用 v3。 |
| [防停滞方案](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/workflow-anti-stall-options-20260830T094403Z.md) | work/artifact/trigger/attempt 身份、租约、实质推进、等待 owner、去重与有界重试；当时外部 ledger/Temporal 的部署建议不是当前已批准路线。 |
| [通用工作流图](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260830/generic-team-operating-workflow.html) | 历史视图，不代替当前 live 权限或配置，也不能假定包含后来增加的 autopilot。 |

## 2026-09-05：增量审计与补充

| 文件 | 历史主题 / 对本轮的价值 |
|---|---|
| [增量审核主报告](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260905-incremental/report.md) | MY-1531 encrypted function output 解码失败，Supervisor rerun 被权限门拒绝，没有 live actor；5个恢复窗口案例仍未交付。 |
| [Quarantine ownership gap](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260905-incremental/report-quarantine-ownership-gap.md) | PR Manager 越权创建 follow-up/改生命周期；MY-1532 未分配、零 run，却被当作有效等待事件。 |
| [Terminal quarantine dead end](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260905-incremental/report-terminal-quarantine-dead-end.md) | 将问题标为 terminal quarantine 不会使 required gate 变绿；缺乏真正产生 healthy-runner 证据的 owner/event/deadline。 |
| [全局 SwiftPM cache 删除](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260905-incremental/report-global-cache-deletion.md) | PR Manager 越过角色边界删除机器级共享缓存；需要工具层保护与 task-local 恢复，而非只靠提示。报告中的破坏性命令是事故证据，禁止照着执行。 |
| [该轮通用工作流图](/Users/tianpli/Development/Nas/output/team-workflow-audit-20260905-incremental/diagrams/generic-team-operating-workflow.html) | 已有历史图与原始验证材料入口，后续需按新方案更新，不能宣称本次重新验证了图。 |

## 2026-09-10 至 09-13：VoxPocket、runtime 与 Autopilot

| 文件 / 证据 | 地位与注意事项 |
|---|---|
| [MY-1540 旧 recovery plan](/Users/tianpli/multica_workspaces/6a90176a-ca91-4760-8594-39e1cf97c2a4/61b8ffb64655/workdir/VoxPocket/specs/005-my-1540-recovery/plan.md) | 审查过的历史方案；“先启用 observer”“本地 archive/替换 App”已被新 Owner 决策和 TestFlight-only 规则覆盖。不要直接重放整个旧任务图。 |
| [旧任务图](/Users/tianpli/multica_workspaces/6a90176a-ca91-4760-8594-39e1cf97c2a4/61b8ffb64655/workdir/VoxPocket/specs/005-my-1540-recovery/tasks.md) | T001–T017 来源；当前语音测试只涉及 T009–T013 的有效合同。 |
| [旧证据数据模型](/Users/tianpli/multica_workspaces/6a90176a-ca91-4760-8594-39e1cf97c2a4/61b8ffb64655/workdir/VoxPocket/specs/005-my-1540-recovery/data-model.md) | 可借用 cold/warm、身份、恢复和完成证据字段；不继承已过时的全部前置条件。 |
| [整体整理 Prompt](/Users/tianpli/Development/Skills/workflow-reconciliation-prompt.md) | 9/12 已提交到 Skills 的 `12dc343`；新 session 同时读取当前交接报告，补上最新证据和 Owner 的停止调查决定。 |
| [Autopilot 责任合同](/Users/tianpli/Development/Skills/team-workflow-audit/references/autopilot-contract.md) | 观察/分发/有界重试/升级与 Dev Team 实现边界；区分 GitHub rerun 和 Multica rerun。 |
| [LeePepe 全账户登记](/Users/tianpli/Development/Skills/team-workflow-audit/references/leepepe-github-autopilot-registration.md) | 全部 owned repos、任意 PR 作者的期望覆盖；不是线上已迁移或已运行的证明。 |
| [Audit skill](/Users/tianpli/Development/Skills/team-workflow-audit/SKILL.md) / [Authority](/Users/tianpli/Development/Skills/team-workflow-audit/references/workflow-authority.md) | skill 显式调用且只读；Owner 最新决定高于旧 plan；审计批准不等于修复执行授权。 |
| [当前 App 仓库规则](/Users/tianpli/Development/VoxPocket/AGENTS.md) | 主目录可能落后远端；引用前刷新读到的版本，修改与分支操作保持隔离。 |
| [日志 PR #35](https://github.com/LeePepe/VoxPocket/pull/35)、[PKG 修复 #37](https://github.com/LeePepe/VoxPocket/pull/37)、[scheme 修复 #38](https://github.com/LeePepe/VoxPocket/pull/38) | 本次已完成代码交付案例；不能由 merge 推断真实 App 日志已入库。 |
| [Mac TF run 34697911858](https://github.com/LeePepe/VoxPocket/actions/runs/34697911858) | macOS1.0(39) 上传/processing 成功，分组调用报告非致命错误；后来 Owner 截图确认 Internal 中 Testing。应设计状态核对，而非盲重传。 |

## 已完成的安全整改

9/12 已轮换 Multica 代理 Basic Auth，并验证新凭据200/旧凭据401、本机网关与中继可用。没有改 NAS 管理密码、Multica Bearer token 或 SSH 私钥。本轮整理不需要读取任何凭据文件。

如确需审计本次结果，仅查看不含密码的 [验证记录](/Users/tianpli/.config/multica/credential-rotations/20260912T134855Z/verification.json)。**不要递归读取该目录**，其中其他文件包含受限凭据与恢复材料。

## 证据使用规则

- 原报告的时间、cohort、统计与 findings 保持原貌；本次摘要不宣称旧 open finding 今天仍 open。
- 相似报错可以关联调查，但不能凭标题/错误词就宣布 duplicate、同一根因或 regression。
- 旧 report/plan 的审批包不等于新 session 已获执行授权；先重新核对 Owner 决策与有效权限。
- 初版、v2/v3 和完成性重跑属于同一批证据的修订，不能把它们算成多个独立样本。
