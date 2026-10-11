# 整体 Workflow 改进交接报告

观测日期：2026-09-13；日志首次查询时间 09:17:06 CST（01:17:06 UTC）。

## 结论与本次边界

这是一份**当前问题取证 + 历史报告索引 + 后续改进输入**，不是重新执行了全部项目的 baseline audit。本次只读查询并编写材料，没有派发任务、修改角色权限、启动 autopilot、重启 App 或更改凭据。历史报告里的建议不自动构成当前执行授权。

| 事项 | 当前确认 | 下一步归属 |
|---|---|---|
| 新 Mac VoxPocket 日志 | 原生 Mac 1.0(39) 正在运行；本地 Loki 正常，但查询未见匹配的 App 日志 | App 日志配置/端到端验收；同时纳入 workflow 的“实际使用证据”阶段 |
| MY-1555 | 仅准备基准工作区的 LokiKit 依赖；blocked，目标目录不存在 | 工作区/依赖准备与角色调用权限交接 |
| Team Lead → Fullstack | 平台返回 `invocation_not_allowed`，没有 Fullstack run | 独立 workflow/platform 改进 session 诊断有效权限和路由 |
| Runner/runtime 恢复 | 人工 VPN + 单个 runner 重启曾恢复审查；长期恢复机制未证明落地 | 同一改进 session 设计并验证 readiness、超时、恢复与升级 |
| NAS autopilot | 配置记录 active，但定时 trigger disabled；Owner 明确暂缓 | 只纳入整体设计，当前不部署、不启用 |
| TF 客户端显示 | Owner 已找到原因并要求停止排查；截图确认 39/macOS 与 38/iOS 都在 Internal 中 Testing | 关闭本会话的显示问题调查，不重新开题 |
| 凭据轮换 | 9 月 12 日已完成：新 Basic Auth 200、旧 401，网关可用 | 已完成；不得因整理 workflow 再轮换或读取凭据正文 |

建议先处理**有效调用权限与真实交接**，因为它直接阻塞已批准的语音测试；日志上传问题可作为独立 App 验收案例，不应阻塞整个 workflow 整理。

## 1. 新 Mac App 的日志检查

### 现场证据

- 进程 PID `48905`：`/Applications/VoxPocket.app/Contents/MacOS/VoxPocket`。
- 安装包 Info.plist：版本 `1.0`，build `39`；这次不是之前在 Mac 上运行的 iOS build 38。
- `http://localhost:3100/ready` 返回 `ready`。
- 以下 LogQL 都返回 `status=success`、`data.result=[]`：

```logql
sum(count_over_time({app="VoxPocket",stream="log"}[1h]))
sum(count_over_time({app="VoxPocket",stream="log"}[48h]))
sum by (stream) (count_over_time({app="VoxPocket"}[1h]))
sum(count_over_time({app=~".*[Vv]ox[Pp]ocket.*",stream="log"}[48h]))
```

含义是：**这个本地 Loki 实例在这些查询窗口没有匹配数据**。不是断言 App 没有产生 stdout/系统日志，也没有检查用户转写正文。

### 已知配置行为与未验证部分

已合并的 `VoxPocketLogging.endpoint(environment:)` 优先读取 `LOKI_ENDPOINT`；仅 `DEBUG && os(macOS)` 在缺少变量时自动使用本机 Loki，Release 则返回 nil。`start()` 在没有 endpoint 时直接退出，不启用远程 sink。

因此，“Release 日志端点是否实际配置”是第一检查点；**没有读取运行进程的完整环境，也没有证明该进程一定缺少变量**，不能把这个候选原因当作已验证根因。

代码依据：[VoxPocketLogging.swift，PR #35 合并版本](https://github.com/LeePepe/VoxPocket/blob/5a78d9240274860bc5c7fc2bbadcfa4eb0055f41/VoxPocket/VoxPocket/VoxPocketLogging.swift)。

### 后续验收标准

1. 在不展示 secret、转写文本或任意错误正文的前提下确认 Release sink 的实际启用状态。
2. 若要重启，先确认没有录音和未保存文本；不要强制终止 App。
3. 使用真实安装版的启动及无害窗口操作，核对 `app=VoxPocket, stream=log, build=39`，在有明确起止时间的窗口内看到对应白名单标记。
4. 检查字段只含批准的固定消息和数值；SDK smoke log 不能代替真实 App 证据。
5. 设计正常 TestFlight 使用方式下可维护的日志配置入口，不仅靠 Debug 默认开启或一次性终端环境变量。配置方案本身需单独确认，不在本报告中实现。

## 2. MY-1555 到底做什么

**标题**：`[T009] Provision pinned task-local LokiKit`。

它不是语音识别，也不修改 LokiKit。它只把依赖检出到 VoxPocket 基准工作区的同级目录，固定到已发布版本，让 `Packages/VoxInfrastructure/../../../LokiKit` 正确解析。

### 当前 issue 原文的任务要求

```text
Reviewed task T009 / US4 at revision 881da19a738a9685bc5a6cd2581ef1abc7756ac0.

Layer and scope: RepoInfra dependency workspace.
Provision <task-root>/LokiKit with:
multica repo checkout https://github.com/LeePepe/LokiKit --ref eff9c1712cd648ed0717e41183ad8bd7bf39cbea

Exclusions:
No LokiKit source edits, branch change, commit, cleanup, push,
global cache change, or primary checkout.

Acceptance:
Absolute resolved path, authoritative origin, exact published SHA,
clean state, source_edits=false.

Verification:
git -C <task-root>/LokiKit remote get-url origin
git -C <task-root>/LokiKit rev-parse HEAD
git -C <task-root>/LokiKit status --porcelain
Resolve Packages/VoxInfrastructure/../../../LokiKit.

Original dependencies: T008. Blocks T010 and T012.
```

上面是原 issue 要求，不是本报告已执行的命令。9 月 12 日的 Owner 更新已明确：PR #35 合并满足实际前置交付，基准不再等待暂停的 autopilot；父任务 MY-1544 的完整新 brief 和子任务调度评论是当前范围依据。**旧 description 里的 T008 与新调度合同应统一，不能让执行者继续陷入旧依赖等待。**

### 当前准备状态

- 父任务：MY-1544，UUID `dbcf2e4a-ad46-4ca1-8fb0-dc4aaeb4c101`，in_progress。
- MY-1555 UUID：`d0a16999-111e-4f7f-ba67-f68f741ed47f`，blocked。
- 已准备 VoxPocket workdir：`/Users/tianpli/multica_workspaces/6a90176a-ca91-4760-8594-39e1cf97c2a4/9e14c4f2291c/workdir/VoxPocket`。
- 记录的 base：`5a78d9240274860bc5c7fc2bbadcfa4eb0055f41`，branch `agent/team-lead/9e14c4f2291c`。
- 应有的 sibling：同一 `workdir/LokiKit`；本次只读检查确认目录不存在。
- MY-1556（生产 adapter 测试接口）、MY-1557（基准工具）、MY-1558（验证/审查/合并）、MY-1559（真正识别运行）均为 backlog。

因此目前没有各模型的耗时或准确率结果。后续仍按已批准的一次冷启动、五次热运行、同输入、独立计下载/加载/转换、私密报告、禁止静默模型回退的合同执行；本交接不复制音频、参考文本或识别正文。

## 3. 调用权限与交接故障报告

### 已证实的事件链（2026-09-12，CST）

| 时间 | 事件 |
|---|---|
| 21:28:27 | MY-1555 backlog → todo |
| 21:29:02 | Team Lead run `88d2477d-8709-4e93-a1b9-9e14c4f2291c` 开始 |
| 21:30:22 | issue → in_progress |
| 21:31:44 | Team Lead 留下工作区信息并 mention Fullstack，要求执行 T009 |
| 21:32:34 | `squad_leader_evaluated` outcome=failed；issue → blocked |
| 21:32:46 | Team Lead run 结束，run status=completed、error=null |

失败活动 ID：`ea6f40ba-66e2-4c7f-bb6c-7999aa0c6540`。平台保存的 reason：

> Provisioned and persisted clean VoxPocket workspace, but Fullstack mention was blocked with invocation_not_allowed; live roster UUID is correct and no Fullstack run was created.

本次 `issue runs` 仍只有上述 Team Lead run，没有 Fullstack run。**run completed 并不代表任务成功，更不代表下一角色已接单。**

### 当前绑定与已知限制

- Workspace：`my` / `6a90176a-ca91-4760-8594-39e1cf97c2a4`。
- Dev Team：`741fb417-c6b0-4df7-b505-03396ccbf77b`。
- Team Lead：`77b2d5cd-2619-4877-96fa-9d7fee21a710`。
- Fullstack：`105247d0-e4e1-47bc-b919-fb6c932f6efe`。
- 当前 Mac daemon：`019fd055-0738-723e-a556-762fc863b720`。
- Codex runtime `ab653716-b90e-40f1-b6ff-5095f818a1f8` 与 Copilot runtime `05eda9df-e582-43e1-b8e0-3c16f847522d` 均 online，均属于该 daemon；本次 last_seen_at 为 2026-09-13T01:18:33Z。
- Team Lead 的公开 `invocation_targets` 字段是空数组；它的**有效权限语义未验证**。空数组不能直接等同于允许全部或拒绝全部，也不能替代 squad、调用者、目标、任务上下文的有效权限检查。

### 改进 session 必须查清的内容

1. 精确定位拒绝发生在 CLI、服务端 policy、squad 权限、角色边、请求上下文还是路由解析；记录当前部署版本和适用规则。
2. 将“文档允许 TL→FS”与“平台实际允许调用”做逐边对照。明确最小权限修复，而非全角色放开。
3. handoff 完成条件必须是目标真实接受并产生 run，不能仅凭 mention 成功写入。
4. 失败要返回有负责人、下一事件和 deadline 的恢复链；保留权限拒绝证据，不用反复 rerun 或创建重复任务掩盖。
5. 评估纯依赖准备是否应由 TL 的确定性工作区准备步骤完成；这属于流程设计候选，不授权当前会话绕过已有责任边界。

验收：相同类型的合法 handoff 产生一个且仅一个预期 Fullstack run；不允许的调用明确失败并有升级负责人；工作区/依赖证据落地后才能推进基准任务。

## 4. Runner/runtime 检查、超时与恢复报告

### 已发生、不能混为一谈的故障

| 故障 | 已有证据 | 当前结论 |
|---|---|---|
| GitHub runner 离线 | 9 月 12 日 GitHub 显示 offline，launchd 进程仍存在；日志连接重试；仅重启该空闲 runner 后恢复 online 并接单 | 人工恢复成功，长期机制未验证 |
| Provider 网络不可达 | 9 月 11 日本机 ChatGPT 443 连接超时，而 GitHub HTTP 200；review 重连，后来取消 | 与代码 finding 分开；VPN 恢复后的实际 review 才是验证，不是主页 HTTP 响应本身 |
| 加密函数输出无法解码 | Planner run `c2d9672d-013b-440b-9c2a-199a4b32168c`；后续 TL run `b0e2da63-91a2-4912-8511-54daf736c103` 同类 `invalid_request_body` | 根因未证实；不能断言都是换电脑或 VPN 导致 |
| 模型/认证方式不兼容 | 早期 NAS observer 两次启动失败，提示所选模型不支持其 ChatGPT 认证方式 | 历史事实；重新启用前需查当前 runtime catalog，不做盲试 |
| 调用权限拒绝 | 本报告 §3 的 `invocation_not_allowed`，runtime 在线但 FS 无 run | 当前明确的执行阻塞，重启 runner 不会自动修正有效权限 |

人工恢复后的 PR #35 审查：run `34616044609` 第 2 次尝试通过，2026-09-12T01:25:30Z 自动合并；这只证明该次执行恢复，不证明所有 runtime 问题根治。

### 现有机制与建议要分开

现有 `codex-review-target.yml` 有 `timeout-minutes: 25`。此前取证包括手动查询 GitHub runner、launchd、网络探针、日志与实际重跑结果。**下表是待评审的设计建议，不是已经部署的自动恢复系统。**

| 检查层 | 怎么检查 | 建议时限/动作 |
|---|---|---|
| 派发资格 | 有效调用权限、角色/daemon 绑定、工作区和依赖可达、相同任务是否已有 run | 不满足立即返回明确 blocker，不排一个永远不能执行的队列项 |
| 网络与认证 | 在真实 runner 服务环境中验证 DNS/TCP/TLS 和最小认证请求；日志脱敏 | 单次 TCP 约 5 秒、TLS/HTTP 约 10 秒；认证/环境预检整体不超过 120 秒；HTTP 403 不等于认证成功 |
| 接单 | 比较 queued 时间、远端 runner online/busy、实际 task/run ID | 超过 120 秒未接单先归因；忙碌排队与离线分开，不杀正在工作的 runner |
| 运行进展 | 角色/阶段适配的实际进展：新制品、check 结论、已接受 handoff、下载字节等 | review 可先考虑 5 分钟无进展告警、保留 25 分钟硬上限；构建/下载另设阶段阈值。心跳、重复查询、重复状态打印不算实质推进 |
| 恢复 | 对已证实恢复的瞬时故障，原角色/精确候选有界重试 | 网络重试建议最多 2 次，退避并持久记录预算；同 SHA 的 CI infra rerun 可用更严预算。最终值由方案评审统一 |
| 确定性拒绝 | 权限、无效认证、模型不支持、代码 finding | 原样自动重试预算为 0；交给相应 owner。区分手动取消与基础设施取消 |
| 非可恢复会话 | 识别 encrypted-output 错误，检查部署的 session reuse/恢复分类 | 经授权验证一次干净会话路径，不删除凭据/全局会话目录，不反复恢复同一坏上下文 |

持久重试身份至少包括 repo/project、subject、角色、候选 SHA/制品、workflow、失败签名。换 sweep、换进程或无关换 SHA 不能使同因预算凭空归零。跨项目共享网络、缓存与密钥不得作为自动清理对象。

验收：用隔离故障注入验证离线、超时、权限拒绝、坏会话各自进入正确状态；恢复后真实接单并得到合法 gate 结果；每个等待态有 owner/next event/deadline；保留故障到恢复的证据链。

## 5. 暂缓的 NAS Autopilot，也纳入整体设计

当前 Owner 决策：**先不部署/启用，先整理整体 workflow**。

- 现有 native autopilot：`d67e7307-d0ef-40c4-a597-fd48d73cda48`，显示名仍是 `VoxPocket Log Delivery Supervisor`。
- 关联项目仍是 VoxPocket `9d01895c-eb6b-44e7-84ee-ec382cf54ca5`，不是已经覆盖全账户的线上部署。
- 记录 status=active，但 trigger `52310b59-fd61-4cf7-ae14-523ae55d2a26` 的 `enabled=false`；配置为每 10 分钟，最后触发时间 2026-09-10T14:50:03Z。
- 已登记意图是全部 `LeePepe/*`、不限 PR 作者；文档范围不能当作实际覆盖证明。

未来方案边界：NAS 只负责观察、分发、有界 rerun、去重和升级；Dev Team 的实现角色仍在 Owner 指定的同一物理电脑/daemon，可以分别使用 Codex/Copilot runtime。Autopilot 不修改代码、模型/凭据/网络、不代替 review、不绕过 required gate。外部作者 PR 由 PR Manager 根据准确 repo/issue/workdir/base/head/scope/evidence 接管。

整改设计需先明确：唯一监督责任人、会话监督与定时监督去重、仓库动态发现与缺口、机器不可用时的等待负责人、持久预算、成功 probe、覆盖证明。不要让 observer 的上线强依赖它本应监督的未完成修复，也不要让暂停 observer 阻塞独立可执行的语音测试。

## 6. 历史报告与本次问题的关系

完整入口见 [历史资料索引](workflow-improvement-history-2026-09-13.md)。

| 历史主题 | 本次对应问题 | 使用方式 |
|---|---|---|
| 8/30 高重复、无下一负责人、缺版本/触发身份 | MY-1555 有 mention 无目标 run；父 in_progress、子 blocked | 延续 owner/next-event/attempt identity 设计，不混算两个日期的 cohort 指标 |
| 9/5 加密输出错误 + Supervisor rerun 权限拒绝 | Planner/TL 解码错误及 TL→FS 调用拒绝 | 同类故障线索，不等于已证明同一个底层根因或某修复 regression |
| 9/5 quarantine 没有实际恢复事件 | “等健康 runner/下个 agent”却无可执行 owner | 任何等待都必须有真实恢复入口、权限和 deadline |
| 9/5 PR Manager 删除全局缓存 | 本次依赖准备明确禁止全局缓存改动 | 把禁止事项落实到可验证的工具/权限边界，而不只是文档提示 |
| 本次 TF 非致命分组错误与绿色 workflow | 上传/processing/分发/客户端可见/使用效果并非一个状态 | 必须读真实状态；不能将日志警告直接当未分发，也不能将 success 当全部已验收 |

8/30 防停滞方案曾建议外部账本/门卫甚至 Temporal；后来 Owner 选择复用 Multica native autopilot。其幂等、租约、事件身份思想可参考，**外部调度器部署不是当前已批准路线**。旧 recovery plan 的“先启用 observer”“本地 archive 替换 App”也不能覆盖后来的暂停决定和 TestFlight-only 交付规则。

## 7. 建议另一个 Session 的交付物

1. 当前 authority/source-of-truth 地图：Owner 决策、仓库规则、团队角色指令、平台有效权限分别是什么，冲突如何解决。
2. 完整角色交接与状态机：需求→规划→实现→review→PR/CI→merge→release→可使用→实际效果；每条边都有被接受的证据和失败返回路径。
3. 有效权限矩阵及 MY-1555 的最小修复方案，保留隔离工作区和 provider 分工。
4. 故障分类、接单/无进展/总超时、持久重试预算、隔离恢复测试与回滚方案。
5. paused autopilot 的将来接入位置；不在本轮自动启用。
6. 文档合并/去重/过时标记清单，以及构建/发布/真实日志的分层验收合同。

每项给出负责人、确切修改对象、验收证据、风险和回滚。先报告方案再等待 Owner 明确批准实施；如果使用 `$team-workflow-audit`，遵守其只读边界和采样/报告规则，修复属于另一个明确授权阶段。

## 可直接复制到另一个 Session

```text
请先阅读：
/Users/tianpli/Development/LokiKit/docs/workflow-improvement-handoff-2026-09-13.md
/Users/tianpli/Development/LokiKit/docs/workflow-improvement-history-2026-09-13.md
/Users/tianpli/Development/Skills/workflow-reconciliation-prompt.md

以这些当前证据和历史报告为输入，整理整个 Dev Team/Multica/GitHub/发布/效果验收 workflow。
重点查清 MY-1555 的 invocation_not_allowed、真实 handoff 与等待责任、runtime 的检查/超时/恢复，
同时把暂缓的 LeePepe 全仓库 native autopilot 纳入设计。先只读取证和给整改方案，确认后再实施。
不要重新排查我已找到原因的 TF 显示问题，不重新轮换已完成的凭据，不启用暂停的 autopilot。
不要读取或输出凭据、音频、参考文本和识别正文。历史报告的状态/建议要与最新 Owner 决策重新核对。
```

## 可重复的只读取证入口

```bash
multica --workspace-id 6a90176a-ca91-4760-8594-39e1cf97c2a4 issue get MY-1555 --output json
multica --workspace-id 6a90176a-ca91-4760-8594-39e1cf97c2a4 issue timeline MY-1555 --output json
multica --workspace-id 6a90176a-ca91-4760-8594-39e1cf97c2a4 issue runs d0a16999-111e-4f7f-ba67-f68f741ed47f --output json
multica --workspace-id 6a90176a-ca91-4760-8594-39e1cf97c2a4 issue children MY-1544 --output json
```

仅选取所需字段展示；不要将任意 metadata、完整配置、认证头或模型原始会话批量输出。运行记录与本机路径是调查定位线索，重新观察后才能用于修改操作。
