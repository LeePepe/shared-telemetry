# Telemetry Collection

共享遥测采集的领域词汇，用于讨论来自 App 和服务的观测记录。

## Language

**Telemetry Record（遥测记录）**:
一次观测所产生的记录；它只包含获批准的事件信息或白名单诊断信息，不代表用户内容本身。
_Avoid_: 用户原文、任意控制台输出

**Telemetry L1（遥测贴源层）**:
保留通过隐私规则的遥测记录及其来源上下文，作为后续整理与分析的事实依据。
_Avoid_: 未过滤原文、指标汇总层、VitalStride 的 HealthKit L1 缓存

**Telemetry Batch（遥测批次）**:
一起提交的一组遥测记录；批次的身份与其中每条记录的身份不同。
_Avoid_: 单个业务事件、会话

**Derived Result（派生结果）**:
由保留的源记录和明确的处理规则产生的明细模型、统计指标或分析产出。
_Avoid_: 原始事实
