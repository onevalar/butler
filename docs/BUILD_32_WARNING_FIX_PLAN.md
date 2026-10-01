# Build 32 警告修复计划

日期：2026-10-02。状态：待实施；本文不是修复完成声明。

## 基线与范围

- 基线提交：`6144b6a`，此前代码修复为 `04e5aa9`。编写时工作区没有未提交代码，已有代码修改均在 main 与 origin/main。
- 证据：用户提供的 Build 32 archive、build-for-testing、iPhone 17 Pro test-without-building、Combine Multiple Test Destination Results 四份日志 ZIP。
- 日志确认：Test Build、Test Execute、Archive、Export 均成功；571 个测试，1 个跳过，0 个失败。主应用、分享扩展和小组件此前的签名阻塞本次已消除。
- 日志不包含 TestFlight 内外部 Post-Actions 的最终结果，不据此宣称测试者已获得版本。
- 页面 26／27 是阶段计数，不可相加。下方按文件位置去重保存原始诊断；编译器附带的抑制建议也单列，因此附件提取数量不一定等于页面数量。
- 工程目前使用 Swift 5 语言模式、默认 MainActor 隔离。不能为清零警告全局取消隔离、关闭诊断、直接迁移 Swift 6，或删除现有功能。

## 实施顺序与验收

每项完成后更新状态、提交 SHA 和验证结果。优先级 P1 为并发与数据行为，P2 为接口及声明清理，P3 为构建提示。所有项目初始状态均为待实施。

| 编号 / 优先级 | 范围 | 明确修复步骤 | 验收标准 |
|---|---|---|---|
| W01 / P1 | LiveDictation.swift:432、482；RealtimePCMConverter.swift:24；两个文件的导入提示 | 核实 AVAudioConverter 输入回调是否同步消费缓冲区及每个 converter 的独占线程；保留音频线程处理，跨 actor 仅传已拥有的 PCM Data 或标量；异步识别回调使用稳定捕获并在 MainActor 校验会话 ID。只有核实框架并发契约后才允许局部兼容导入或受控包装，不能只加 unchecked Sendable 掩盖风险。 | 音频并发诊断消失；原生、文件转写、实时转写保持可用；连续取消后重按至少 3 次、准备中取消、迟到回调、后台退出不串会话、不重复发送；保持立即触觉、短按输入、长按语音、液态玻璃及无环形进度约束；真机录音无截断，PCM 仍为 24kHz 单声道 PCM16。 |
| W02 / P1 | InventoryGroups.swift:64、66；InventoryQuery.swift:54、60、65、70、78；InventoryPolicy.swift:246；ChineseInventoryParser.swift:352、355、356 | 对默认 MainActor 下的方法引用转闭包逐处审查；优先在当前隔离作用域显式调用。仅对不访问模型、UI或可变共享状态的纯值辅助方法显式 nonisolated，避免把 SwiftData 对象送往后台。 | 全部相关隔离警告消失；分类/位置/到期分组、紧急排序、查询回退、中文数量识别和日期确认 identity 的既有测试通过，排序与确认结果不变。 |
| W03 / P1 | Models/V2/InventoryEvent.swift:54；Domain/InventoryOperationPlan.swift 的 InventoryOperation/Codable 依赖 | 核对操作 DTO、关联类型、编码工厂的隔离边界；按实际调用方将纯值 Codable 协议实现设为可跨隔离使用，或将解码限定在正确 actor。禁止改 JSON 格式或去掉 revision 校验。 | Codable 隔离警告消失；旧 payload 可解码，数量撤销及关闭批次撤销保持 revision/溢出保护；库存计划编码、持久化、撤销相关测试通过。 |
| W04 / P1 | Services/SubscriptionModel.swift:16、17、154、155 | 明确默认 instructions/tools 提供闭包的 actor 类型与调用位置；在 MainActor 内创建并调用，或将真正不可变、纯值内容生成抽离。继续按每次请求读取动态上下文，不能用初始化缓存替代。 | 4 处诊断消失；首次和后续请求上下文/工具定义正确，工具轮次、流式输出、配置变更、取消及凭据保护相关测试通过。 |
| W05 / P1 | Services/Agent/ChatDiagnostics.swift:18、22 | 将固定 limit 明确为非隔离常量；审查多个回调同时追加、截断文件时的访问，必要时以专用串行写入或锁保护完整文件事务，避免阻塞音频线程。 | 两处隔离诊断消失；并发日志不互相截断，容量轮转有效，失败可容忍；不写入 API key、Authorization 或完整敏感请求。 |
| W06 / P2 | Design/Theme.swift:103 | 在字体候选遍历中保留 UI 字体查询的主线程隔离，使用显式隔离内调用，不能为消警告随意把 UIFont 查询标记 nonisolated。 | 字体诊断消失；字体注册、中文字重和缺字回退正常，界面视觉不变。 |
| W07 / P2 | Services/AlarmKitDevice.swift:52 | 核对当前 SDK 的 Alert 新初始化接口；iOS 26.1+ 使用受支持接口，按部署版本为旧系统保留必要 availability 分支。保留停止、稍后提醒及倒计时行为。 | 无弃用警告；闹钟规则与工具测试通过；真机一次性/重复/倒计时闹钟能停止，已有按钮行为无回退。 |
| W08 / P2 | Models/Item.swift:111，SwiftData 宏展开重复 Sendable；ButlerTests/JevEvaluationTests.swift:179 | 检查 SwiftData 已生成的 Sendable 与现有跨线程使用，去掉重复显式声明前确认模型只在正确 ModelContext/actor 使用；调整 retained 声明但保留弱引用释放断言的真实含义。不要编辑宏生成文件。 | 重复声明与变量警告消失；数据存储、导入导出、Jev 生命周期测试通过，弱引用测试仍能发现对象未释放。 |
| W09 / P3 | AppIntents 元数据提示；重复模拟器目的地提示 | 从完整命令确认提示对应的具体 target；没有 AppIntent 的 target 保留并记录提示，不为了消警告引入空依赖或关闭真实元数据提取。模拟器本机验证用 UDID 明确目标；Xcode Cloud 默认 runtime 若产生重复提示，记录为环境提示，除非能在受支持配置内消除。 | 真正有 AppIntent 的主应用/小组件元数据仍生成，快捷指令和闹钟操作正常；测试运行在预期 iPhone 17 Pro runtime。允许有依据的环境提示保留，不能承诺所有黄色计数必定为零。 |

## 验证与发布门槛

1. 用 Xcode 26.3 对 Debug 测试编译和 Release 归档编译分别提取诊断，按下面的位置逐项核对；宏生成行号可能变化，按 Item 源声明定位。
2. 并发修改增加或调整能覆盖取消/迟到回调、数据竞争或旧 payload 的有效测试；不添加仅复述实现的测试。定向测试通过后做一次完整英文美国区域回归，记录总数、跳过原因和失败数，与 571/1/0 基线比较。
3. 语音、字体、闹钟等真机行为按各行验收。模拟器及单元测试不能替代马达、麦克风和系统闹钟验证。
4. diff 检查、凭据检查、MainActor/Sendable 使用审查通过。所有代码警告应清除；框架兼容处理和保留环境提示必须附具体证据、范围及原因。
5. 实施后更新本计划的每项状态。提交推送仍不自动触发云构建；只有用户要求发布时手动构建一次，检查 Test、Archive、Export、内部/外部分发及 TestFlight 可测试状态。

## 原始警告清单（按阶段及文件位置去重）

以下来自 Build 32 实际日志，保留编译器英文诊断，供后续验收比对。文件行号对应基线提交，不是未来修改后的固定位置。

### Archive

- `Butler/Design/Theme.swift:103:40` — warning: call to main actor-isolated static method 'isAvailable' in a synchronous nonisolated context
- `Butler/Domain/InventoryGroups.swift:64:66` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryGroups.swift:66:35` — warning: call to main actor-isolated static method 'needsAttention' in a synchronous nonisolated context
- `Butler/Domain/InventoryPolicy.swift:246:59` — warning: call to main actor-isolated static method 'dateIdentity' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:54:26` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:60:76` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:65:81` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:70:100` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:78:22` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Models/V2/InventoryEvent.swift:54:79` — warning: main actor-isolated conformance of 'InventoryOperation' to 'Decodable' cannot be used in nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/Agent/ChatDiagnostics.swift:18:59` — warning: main actor-isolated static property 'limit' can not be referenced from a nonisolated context
- `Butler/Services/Agent/ChatDiagnostics.swift:22:38` — warning: main actor-isolated static property 'limit' can not be referenced from a nonisolated context
- `Butler/Services/AlarmKitDevice.swift:52:39` — warning: 'init(title:stopButton:secondaryButton:secondaryButtonBehavior:)' was deprecated in iOS 26.1: stopButton is deprecated and will no longer be used
- `Butler/Services/ChineseInventoryParser.swift:352:49` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/ChineseInventoryParser.swift:355:64` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/ChineseInventoryParser.swift:356:69` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/LiveDictation.swift:1:1` — warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'
- `Butler/Services/LiveDictation.swift:432:24` — warning: capture of 'buffer' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure
- `Butler/Services/LiveDictation.swift:482:27` — warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
- `Butler/Services/RealtimePCMConverter.swift:1:1` — warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'
- `Butler/Services/RealtimePCMConverter.swift:24:20` — warning: capture of 'buffer' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure
- `Butler/Services/SubscriptionModel.swift:154:103` — warning: main actor-isolated static property 'instructions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:155:66` — warning: main actor-isolated static property 'toolJSON' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:16:69` — warning: main actor-isolated static property 'instructions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:17:62` — warning: main actor-isolated static property 'toolJSON' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler4Item5ModelfMe_.swift:9:17` — warning: redundant conformance of 'Item' to protocol 'Sendable'
- `构建工具` — warning: Metadata extraction skipped. No AppIntents.framework dependency found.

### Build for testing

- `Butler/Design/Theme.swift:103:40` — warning: call to main actor-isolated static method 'isAvailable' in a synchronous nonisolated context
- `Butler/Domain/InventoryGroups.swift:64:66` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryGroups.swift:66:35` — warning: call to main actor-isolated static method 'needsAttention' in a synchronous nonisolated context
- `Butler/Domain/InventoryPolicy.swift:246:59` — warning: call to main actor-isolated static method 'dateIdentity' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:54:26` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:60:76` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:65:81` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:70:100` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Domain/InventoryQuery.swift:78:22` — warning: call to main actor-isolated static method 'urgencyOrder' in a synchronous nonisolated context
- `Butler/Models/V2/InventoryEvent.swift:54:79` — warning: main actor-isolated conformance of 'InventoryOperation' to 'Decodable' cannot be used in nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/Agent/ChatDiagnostics.swift:18:59` — warning: main actor-isolated static property 'limit' can not be referenced from a nonisolated context
- `Butler/Services/Agent/ChatDiagnostics.swift:22:38` — warning: main actor-isolated static property 'limit' can not be referenced from a nonisolated context
- `Butler/Services/AlarmKitDevice.swift:52:39` — warning: 'init(title:stopButton:secondaryButton:secondaryButtonBehavior:)' was deprecated in iOS 26.1: stopButton is deprecated and will no longer be used
- `Butler/Services/ChineseInventoryParser.swift:352:49` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/ChineseInventoryParser.swift:355:64` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/ChineseInventoryParser.swift:356:69` — warning: call to main actor-isolated static method 'chineseInteger' in a synchronous nonisolated context
- `Butler/Services/LiveDictation.swift:1:1` — warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'
- `Butler/Services/LiveDictation.swift:432:24` — warning: capture of 'buffer' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure
- `Butler/Services/LiveDictation.swift:482:27` — warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
- `Butler/Services/RealtimePCMConverter.swift:1:1` — warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'
- `Butler/Services/RealtimePCMConverter.swift:24:20` — warning: capture of 'buffer' with non-Sendable type 'AVAudioPCMBuffer' in a '@Sendable' closure
- `Butler/Services/SubscriptionModel.swift:154:103` — warning: main actor-isolated static property 'instructions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:155:66` — warning: main actor-isolated static property 'toolJSON' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:16:69` — warning: main actor-isolated static property 'instructions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler/Services/SubscriptionModel.swift:17:62` — warning: main actor-isolated static property 'toolJSON' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- `Butler4Item5ModelfMe_.swift:9:17` — warning: redundant conformance of 'Item' to protocol 'Sendable'
- `ButlerTests/JevEvaluationTests.swift:179:18` — warning: weak variable 'retained' was never mutated; consider changing to 'let' constant
- `构建工具` — warning: Metadata extraction skipped. No AppIntents.framework dependency found.
- `构建工具` — warning: Using the first of multiple matching destinations:

### Test execution

- `构建工具` — warning: Using the first of multiple matching destinations:

