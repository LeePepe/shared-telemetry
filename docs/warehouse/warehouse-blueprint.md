# L1 Blob 试点：方案访谈记录

状态：设计访谈中。本文不是实施授权或已完成方案。

## 已确认范围

- 第一阶段只接通 L1，使用 VoxPocket 与 VitalStride 作为案例。
- 目标是获批准的 telemetry 可以上传到私有 Azure Blob。
- 云端持久保存安全的贴源记录及必要批次元数据；L2–L5、dashboard、Databricks 不在本阶段。
- 本地查看工具离线不影响上传和云端保存。
- 保留现有日志、容器、卷和未获批准变更的资源；不调整 VPN。
- 本轮提供方案并访谈确认，不实施代码、部署或发布。

## 术语

共享词汇见 [CONTEXT.md](../../CONTEXT.md)。词汇表只记录领域含义，部署与实现决策留在本文件或适用的 ADR 中。

## 决策树

- 试点受众与运行用途 → 订阅资格 → 设备授权与撤销方式。
- 两个 App 的现行架构及规则（只读调查）→ 平台范围 → 适配归属与独立交付边界。
- 首批观测范围 → 数据契约、白名单与固定验收标记。
- 上传时效目标 + 数据量 → 合批、断网保留、容量上限、丢弃及失败可见性。
- 月度预算目标 + 用途及数据量 → 地域、资源复用/隔离、最终费用审批。
- 保留期与删除授权 → 生命周期策略与可重建范围。
- 上述决策收敛 → 合成验收、真实 App 验收、回滚与部署后费用复核。

## 待确认

试点设备/用户范围、各 App 平台、首批事件集合、上传时效、月度预算、授权模型、部署范围、保留期及失败策略尚未最终确认。

## 仓库事实

- LokiKit 本地 main 快照：`eff9c1712cd648ed0717e41183ad8bd7bf39cbea`。已存在 Swift、Python 和 TypeScript 采集路径；本轮不会假设它们的传输、隐私及持久化保证一致。
- VitalStride 本地 main 快照：`66d52bade550757bb697959d5a311fc5e7570b3b`。`Packages/TelemetryKit` 使用 Aptabase，已有 provider fan-out，并不依赖 LokiKit。Blob 接入可以评估新增 provider；是否保留既有目的地仍需确认。
- VitalStride 的 `L1` 另指 HealthKit 本地缓存。本试点统一称 Telemetry L1，禁止把健康缓存当作上传源；其规则允许计数、耗时和元数据，禁止健康数值外传。
- VitalStride 的 iOS 接入已使用 Aptabase；main 的 macOS 入口仍引用 TelemetryDeck，与包和项目配置存在静态不一致。本轮未构建、未修复；是否纳入平台范围须显式决定。
- 未发现 VitalStride 可直接复用的 App 用户登录令牌；HealthKit 授权、CloudKit 同步及模型 API key 不等于 Blob 上传身份。
- VoxPocket checkout 为 `feat/macos-settings-migration` / `2481bc7`；本地 main `688e501` 和 origin/main `9e42464` 均落后于 checkout。已确认 origin/main 有日志镜像入口，而本地 main 没有；后续实现必须先明确基线，不能把旧 main 当作当前交付状态。
- VoxPocket 当前工作区规则明确仅推进 macOS、暂停 iOS 开发发布。白名单日志镜像 `LokiLogSink` 与通用 `LokiTelemetryService` 是两个路径，前者的隐私及缓冲保证不能套用到后者。

## 第一轮：当前决策前沿

以下均为推荐答案，尚未获得用户确认。

1. 试点受众：建议仅用户本人及明确批准的测试设备，默认关闭、逐台开通，不向现有所有用户默认开启。
2. 平台范围：建议 VoxPocket macOS + VitalStride iOS；本轮不恢复 VoxPocket iOS，不处理 VitalStride macOS 既有接入漂移。
3. 首批观测范围：建议启动、各 App 一个代表性操作的成功/失败与耗时、上传健康；仅固定标识、枚举及批准的计数/时长，不采集通用日志正文或健康数值。
4. 既有目的地：建议 Blob 作为试点新增目的地，保留既有 Loki/Aptabase，不在本轮替换、停用或迁移；新旧目的地失败相互隔离。
5. 预算警戒线：建议两个 App 合计 HK$20/月告警目标；这是方案约束而非费用保证或硬性停费开关，实际资源范围与费用另行确认。

下一轮由本轮答案解锁：授权与撤销、上传时效、离线容量与丢弃策略、资源与订阅、保留期和验收细节。

## 决策记录

尚未新增 ADR。受众、授权、保留与资源边界形成真实决策后，只为满足不可轻易逆转、有取舍且需要解释的决策建立 ADR。
