# Butler 小当家

通过自然语言管理家庭库存、生活偏好和提醒的 iPhone 应用。手机保存资料并执行工具，云端主模型理解请求；Jev 可选地辅助条件判断。涉及库存和笔记的对话修改先生成提议，用户确认后保存。

## 从哪里开始阅读

| 想了解的内容 | 文档 |
|---|---|
| 软件现在能做什么、怎么运行、Jev 什么时候参与、怎样比较效果 | [功能与工作原理](docs/FEATURES_AND_JEV_GUIDE.md) |
| 按页面/对象分对话、自然语言复杂任务、输入框交互的实现与边界 | [上下文管家与任务](docs/CONTEXTUAL_AGENT_DESIGN.md) |
| 云端构建、TestFlight 更新与配置进度 | [Xcode Cloud](docs/XCODE_CLOUD.md) |
| 产品方向、库存数据结构和技术约束 | [产品与技术规格](docs/BUTLER_2_SPEC.md) |
| 各阶段做过什么、当时如何验证 | [开发日志](DEVELOPMENT_LOG.md) |
| 最初的产品构想 | [历史 MVP 说明](bulter产品说明文档.md) |
| 早期架构研究和宿主实验 | [OpenMinis 参考计划](docs/OPENMINIS_REFERENCE_PLAN.md)、[agent-host 历史实验](agent-host/README.md) |

**阅读注意：**历史日志、规划和实验不等于当前功能。功能说明以注明日期和代码基线的文档为准；行为变化时同时更新说明。旧文档里的 Mac 常驻宿主、仅 Debug 对话入口、全部离线等描述不能直接套用到当前手机版本。

当前说明基线：2026-09-28，`codex/jev-prefetch` 分支的 `93fe6da`。这份源码包含远端主分支更新和 Jev 预取；不代表其他分支或所有已分发安装包都相同。
