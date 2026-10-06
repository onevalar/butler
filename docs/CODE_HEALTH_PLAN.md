# 代码结构与健壮性整理方案

日期：2026-10-06。代码基线：`main` 的 `5b9c3da`。状态：**审查结论与待实施方案，本文涉及的生产代码均未修改。**

本次审查所在的 Mac 有 Xcode 26.3，但没有安装 iOS 26.2 平台组件，无法编译 App 或运行应用层测试。因此下列重构只列方案，等能完整编译、跑全量测试的环境再逐项实施；每一步都必须单独编译并跑全量回归，不与功能修改混在同一提交。

## 1. 验证现状

| 范围 | 最近结果 | 覆盖到的代码 |
|---|---|---|
| 完整 Xcode 编译与应用层测试 | Build 35，2026-10-04，本机 iOS 26.2 模拟器 661 项通过、1 项既有跳过、0 失败；Release 编译通过 | 截至 `84fd591`。之后 10-05 的 5 个提交（截图采集、简报刷新、回复进度、日程总览）**未经 Xcode 编译或应用层测试** |
| 可移植核心测试 | 2026-10-06，macOS 15.7 / Swift 6.2.4：chat 48、alarm 164、warning 5、brief 26、agenda 15，共 258 项通过 | 只编译脚本列出的 Foundation 逻辑，不含 SwiftUI、SwiftData、Apple 系统框架和模型请求 |
| 真机与云端 | 见开发日志各条目 | 多数系统能力仍未真机验收，见 [系统能力扩展清单](SYSTEM_CAPABILITIES_PLAN.md) |

2026-10-06 对核心脚本的修复：

- 脚本原先只在 Linux 运行。生成的测试包未声明平台，macOS 按最低部署版本编译，`@Observable`、`Date.now` 等全部报错。现统一声明 `platforms: [.macOS(.v15)]`，Linux 忽略该项。
- `test-alarm-core.sh` 自 `79b61d5`（截图采集）起无法编译：`ShortcutNavigation` 新引用了 `CaptureInputMode`，它定义在依赖 AppIntents 的 `ScreenshotCaptureIntent.swift`，未加入脚本。现按脚本已有做法，从原文件提取枚举分支生成一个仅含取值的替身，不修改生产代码。分支增减会自动跟随。

下次具备 Xcode + iOS 平台时，第一件事是对 `5b9c3da` 之后的代码跑完整 `xcodebuild test`，确认 10-05 的改动没有破坏 Build 35 的结果。

## 2. 大文件拆分方案

| 文件 | 行数 | 现状 |
|---|---|---|
| `Services/Agent/ButlerChat.swift` | 1118 | 发送、确认、历史压缩、草稿持久化、模型指令都在一个类 |
| `Services/Agent/ButlerTools.swift` | 1097 | `execute` 是约 220 行的大 switch；`confirmResults` 约 150 行；库存搜索与 Jev 核对混在一起 |
| `Views/Agent/ButlerChatView.swift` | 802 | `body` 约 230 行；消息、确认卡、输入区、听写控制在同一视图 |
| `ContentView.swift` | 712 | 30 余个 `@State`，同时负责导航、对话面板、简报按钮、任务快捷操作、分享与快捷指令跳转 |
| `Views/Home/HomeView.swift` | 704 | 首页本体之外还放着 `BriefCard`、`FlowLayout`、`DayPickerPanel`、`AgendaRow` 等十余个共用组件 |

原则：先做**纯搬移**（同一类型拆到多个文件的 extension），行为零变化；再考虑真正的职责拆分。工程使用文件夹同步（`PBXFileSystemSynchronizedRootGroup`），新文件自动加入目标，不需要改 `project.pbxproj`。搬移时 `private` 成员跨文件不可见，需改为默认访问级别，不要顺手改名。

### 第一步：纯搬移，风险最低

1. **ButlerChat**：按现有 `// MARK` 拆为 `ButlerChat.swift`（类型、状态、初始化）、`ButlerChat+Sending.swift`、`ButlerChat+Confirmation.swift`、`ButlerChat+History.swift`（上下文重建、摘要压缩、存取）、`ButlerChatInstructions.swift`（`instructions(jev:profile:)` 模型指令）。`ChatTurn` 与 `ConversationSummary` 必须留在原文件且保持原顺序：`scripts/test-chat-core.sh` 用 `struct ChatTurn:` 到 `/// Older conversation` 两个标记截取这段代码。若移动，需同步改脚本。
2. **ButlerTools**：项目已有 `ItemTools`、`AlarmTools` 等按领域的 `extension ButlerTools`。把库存搜索/预取（`searchInventory`、`prefetch`、`boundedRecords`、`describe`）移到 `ButlerTools+Inventory.swift`，Jev 核对层（`ask`、`reviewTarget`、`reviewAdd`、`gate`）移到 `ButlerTools+Jev.swift`。
3. **HomeView**：把 `BriefCard`、`FlowLayout`、`DayPickerPanel` 和 “Pieces shared by home and the day view” 之后的共用组件移到 `Views/Home/HomeComponents.swift`。
4. **ButlerChatView**：`ChatReplyBubble`、`ChatWorkingIndicator` 已是独立视图，移到单独文件；输入区（`composer`、`inputField`、`trailingButton`、听写控制）抽成 extension 文件。

每个文件一个提交，编译 + 全量测试通过再做下一个。

### 第二步：职责拆分，需要评估

- **`ButlerTools.execute` 分发**：每个领域工具已有自己的 `extension`，可改为各领域返回 `String?` 的处理函数链（已有部分工具这样做），把大 switch 中仍内联的库存/笔记/任务分支下沉。需注意确认流程依赖的 `pending` 状态与 Jev 核对顺序不能变。
- **`ContentView` 状态**：把对话面板相关状态（`chat`、`sessions`、`chatRequest`、`showingChat`、`chatDetent`、`afterChatDismissal`、`voiceScope`）收拢为一个 `@Observable` 的协调对象；首页日期与日程缓存（`listDay`、`browsingMonth`、`overviewInterval`、`agendaCache`）另成一组。10-01 已出现过 ContentView 表达式超出编译器类型检查能力导致云构建失败，这是减少该风险的根本做法。此项涉及导航与面板时序（`onDismiss` 后导航、快捷指令排队），必须在模拟器和真机上回归。
- **重复代码**：14 个工具文件各写一遍 `tools.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0 …)) }.joined(separator: ",")`，其中一半带 `.sortedKeys`、一半不带。可收敛为一个 `ToolSchema.json(_:)` 辅助函数，统一排序以保证模型请求稳定可缓存。改动会影响发给模型的工具描述字节顺序，需确认无测试依赖精确字节。

## 3. 强制解包与崩溃点审查

22 处 `try!`、`as!`、`fatalError` 逐一核对：

| 位置 | 结论 |
|---|---|
| 14 个工具文件的 `try! JSONSerialization` | 安全：序列化写死的字典字面量，结果确定；见上方去重建议 |
| `HomeControl.swift` `signature` 的 `try! encode` | 安全：含 `Double`，非有限值会导致编码失败，但两个调用点（`HomeTools`、`HomeStore.check`）只作用于 `HomeStore.plan` 返回、已经 `validate()` 拒绝非有限值的计划 |
| `ChatScope.swift` `BriefConversation.key` | 安全：编码字段只有字符串、整数、UUID 和枚举 |
| `ChineseInventoryParser.swift` 正则 | 安全：模式均为常量，写错会在测试中立即失败（代码注释已说明） |
| `SystemCalendarTools.swift` `as! [String: Any]` | 安全：编码结构体必得对象 |
| `AppleContactsDevice.swift` `mutableCopy() as! CNMutableContact` | 安全：Apple 文档保证的类型 |
| `VoicePressControl.swift` `init(coder:)` | 标准写法，不会被调用 |
| **`ButlerApp.swift` 创建 `ModelContainer` 失败时 `fatalError`** | **真实风险**：数据库文件损坏、迁移失败或磁盘已满时，每次启动都闪退，用户无法自救，也无法导出备份 |

`ButlerApp` 的建议做法（需你确认交互后实施）：失败时不崩溃，进入一个只读的“数据暂时无法打开”页面，说明原文件已保留、不会被覆盖，提供重试和联系方式；不自动删除或重建数据库。项目约定新增界面交互要先确认，且该改动需完整编译验证，所以本次未修改。

## 4. Swift 语言模式与并发

工程为 `SWIFT_VERSION = 5.0`，同时开启 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 与 `SWIFT_APPROACHABLE_CONCURRENCY`。开发日志多次记录同一类运行时崩溃：对象在非主线程释放时走隐式隔离析构（`swift_task_deinitOnExecutorImpl`），已在 `SubscriptionModel`、`MotionTilt`、`AudioRelay`、`ChatSyncData`、`PhotoSource`、`ConfirmationJournal` 及多个测试替身上逐个加 `nonisolated deinit` 规避。

建议：

1. 短期：凡是可能被后台队列、音频线程或 `Task` 最后持有的 `final class`，新建时默认写 `nonisolated deinit`；在代码审查清单里加这一条，避免继续在云构建或真机上才暴露。
2. 中期：在能完整编译的环境里，单独开一个分支把应用目标切到 Swift 6 语言模式，把编译期诊断全部列出后再评估工作量。Swift 6 会把一部分这类问题提前到编译期。不建议与功能开发同时进行。

## 5. 文档

- `DEVELOPMENT_LOG.md` 原由三段排序不同的内容组成，已统一为按日期新的在前（同日按写入日志的先后），加目录，正文不改；补记 10-05 的提交。
- `docs/FEATURES_AND_JEV_GUIDE.md` 重写为按功能分节的现状说明（首页、对话、物品、任务、天气、系统能力、资料输入、设置），数值对照代码核实；Jev 说明保留为第 10 节，原按日期的补充说明移到附录。
- `docs/SYSTEM_CAPABILITIES_PLAN.md` 每项、`docs/CONTEXTUAL_AGENT_DESIGN.md` 各阶段章节下加“2026-10-06 状态”，标出已推送并经 Build 35 验证、以及被 10-05 提交取代的描述；原文保留。
- 历史文档（`agent-host/`、`docs/OPENMINIS_REFERENCE_PLAN.md`、`docs/BUTLER_2_SPEC.md`、`bulter产品说明文档.md`）开头都已标注历史性质，不搬移，避免破坏既有链接。
