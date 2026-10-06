# Butler 小当家

通过自然语言管理家庭库存、生活偏好和提醒的 iPhone 应用。手机保存资料并执行工具，云端主模型理解请求；Jev 可选地辅助条件判断。涉及库存和笔记的对话修改先生成提议，用户确认后保存。

## 从哪里开始阅读

| 想了解的内容 | 文档 |
|---|---|
| 软件现在能做什么、怎么运行、Jev 什么时候参与、怎样比较效果 | [功能与工作原理](docs/FEATURES_AND_JEV_GUIDE.md) |
| 按页面/对象分对话、自然语言复杂任务、输入框交互的实现与边界 | [上下文管家与任务](docs/CONTEXTUAL_AGENT_DESIGN.md) |
| 接下来逐项接入哪些苹果系统能力、如何验证 | [系统能力扩展清单](docs/SYSTEM_CAPABILITIES_PLAN.md) |
| 云端构建、TestFlight 更新与配置进度 | [Xcode Cloud](docs/XCODE_CLOUD.md) |
| 苹果识别、自定义语音模型与 AiHubMix 实时语音配置 | [语音识别](docs/SPEECH_RECOGNITION.md) |
| 产品方向、库存数据结构和技术约束 | [产品与技术规格](docs/BUTLER_2_SPEC.md) |
| 各阶段做过什么、当时如何验证 | [开发日志](DEVELOPMENT_LOG.md)（按日期新的在前，开头有目录） |
| 验证现状、大文件拆分、崩溃点审查与 Swift 并发建议 | [代码结构与健壮性整理方案](docs/CODE_HEALTH_PLAN.md) |
| 最初的产品构想 | [历史 MVP 说明](bulter产品说明文档.md) |
| 早期架构研究和宿主实验 | [OpenMinis 参考计划](docs/OPENMINIS_REFERENCE_PLAN.md)、[agent-host 历史实验](agent-host/README.md) |

**阅读注意：**历史日志、规划和实验不等于当前功能。功能说明以注明日期和代码基线的文档为准；行为变化时同时更新说明。旧文档里的 Mac 常驻宿主、仅 Debug 对话入口、全部离线等描述不能直接套用到当前手机版本。

当前说明基线：2026-10-06（`5b9c3da`），唯一开发分支为 `main`。各项功能的实现与验收状态见[功能与工作原理](docs/FEATURES_AND_JEV_GUIDE.md)开头的“当前状态一览”；源码与手机已安装版本可能不同，具体分发进度见 Xcode Cloud 记录。

## 验证

- 可移植核心测试（macOS 或 Linux，无需 iOS 平台）：`bash scripts/test-chat-core.sh`，同样运行 `alarm`、`warning`、`brief`、`agenda` 四个脚本。只覆盖 Foundation 逻辑，不能替代应用层测试。
- 类型检查（只需 Xcode，不需 iOS 平台）：`bash scripts/typecheck-catalyst.sh`，用 Mac Catalyst 框架检查整个 App 模块；除已知的 Catalyst 不可用诊断外有任何错误或警告即失败。不链接、不含测试目标。
- 完整验证：Xcode 26.3 并安装 iOS 26.2 平台，运行 `Butler` scheme 的 `xcodebuild test`（测试串行执行）。最近一次完整通过是 Build 35（`84fd591`）。
