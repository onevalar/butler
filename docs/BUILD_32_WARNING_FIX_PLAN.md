# Build 32 警告修复计划

日期：2026-10-02。状态：W01–W08 代码已实施，W09 已审查并记录保留项；Xcode 26.3 编译、完整回归和真机验收仍待完成。本文不是全部警告清零或发布完成声明。

## 基线与范围

- 基线提交：`6144b6a`，此前代码修复为 `04e5aa9`。编写时工作区没有未提交代码，已有代码修改均在 main 与 origin/main。
- 证据：用户提供的 Build 32 archive、build-for-testing、iPhone 17 Pro test-without-building、Combine Multiple Test Destination Results 四份日志 ZIP。
- 日志确认：Test Build、Test Execute、Archive、Export 均成功；571 个测试，1 个跳过，0 个失败。主应用、分享扩展和小组件此前的签名阻塞本次已消除。
- 日志不包含 TestFlight 内外部 Post-Actions 的最终结果，不据此宣称测试者已获得版本。
- 页面 26／27 是阶段计数，不可相加。下方按文件位置去重保存原始诊断；编译器附带的抑制建议也单列，因此附件提取数量不一定等于页面数量。
- 工程目前使用 Swift 5 语言模式、默认 MainActor 隔离。不能为清零警告全局取消隔离、关闭诊断、直接迁移 Swift 6，或删除现有功能。

## 实施顺序与验收

每项完成后更新状态、提交 SHA 和验证结果。优先级 P1 为并发与数据行为，P2 为接口及声明清理，P3 为构建提示。所有项目初始状态均为待实施；当前进度见下方实施记录。

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

## 实施记录（2026-10-02）

W01–W08 的代码与测试统一提交为 [ca21c19](https://github.com/onevalar/butler/commit/ca21c19e58b84874f5fb3c35caabb70a6d045913)。保留 Swift 5 语言模式和工程默认 MainActor，没有全局关闭诊断，没有更改现有触觉、液态玻璃、短按/长按分流或发送流程。

| 编号 | 已实施内容 | 已验证 / 尚待验收 |
|---|---|---|
| W01 | 两个音频文件局部使用兼容导入；实时 converter 加锁；AudioRelay 的实时投递与积压回放使用同一把锁，消费者不得重入 relay；识别及音量回调在 MainActor 任务捕获列表重新弱捕获 self，保留会话 ID 检查，只传文字、布尔值或音量。 | 源码及语法检查通过。新增 relay 并发投递、converter 并发 PCM16 回归测试；Apple SDK 不在 orb 中，这两项和既有取消/迟到回调测试未执行。原生/文件/实时收音、连续取消至少 3 次、后台清理与马达效果待真机验收。 |
| W02 | 所列排序、筛选、日期 identity 和中文数字转换的方法引用改为当前隔离作用域内显式闭包调用；未把模型或查询整体移到后台。 | 源码及语法检查通过；ItemsPage、中文解析、日期确认的 Apple 应用测试待 Xcode 执行。 |
| W03 | 操作计划、联合命令、关联传输值及编码工厂明确为 nonisolated；未改 JSON 字段、编码策略或 InventoryEvent 的 revision/溢出判断。 | 两项跨 actor 旧 payload / 日期 / 数量编码测试通过，完整并发检查下无警告。新增 schema、revision 和溢出撤销测试，SwiftData 持久化及该测试待 Xcode。 |
| W04 | instructions/tools 提供闭包明确为 MainActor；固定默认文本为非隔离不可变常量；每次 POST 仍调用提供闭包，没有初始化缓存。 | 语法检查通过。现有网络替身测试增加同一 model 的第二次请求，断言改变后的上下文和工具定义；因 Keychain、Apple URLSession 流式接口不可用，该应用测试待 Xcode。 |
| W05 | limit 为非隔离常量；专用异步串行队列负责完整文件追加/轮转，调用者不等待磁盘；轮转保留完整 UTF-8 行；错误日志去掉可能回显凭据的描述，简报日志只记字数/动作数，不记模型原文。 | 三项测试通过：400 次并发追加不丢不重、中文轮转及后续并发追加、写入失败可继续且错误描述不含敏感文字。完整并发检查下无警告。 |
| W06 | 字体候选使用显式闭包调用 UIFont 查询；保持原主线程隔离和候选顺序。 | 语法检查通过；未改字体资源或视觉样式。字体注册、中文字重和缺字回退待 Apple 环境渲染验收，orb 无法截图验证。 |
| W07 | 采用 iOS 26.1+ 系统停止按钮的 Alert 初始化接口；工程最低 iOS 26.2，无需旧系统分支。未改重复规则、倒计时、暂停/继续或 stop 调用。 | 便携核心回归含闹钟规则/存储并通过；AlarmKit SDK 编译及一次性/重复/倒计时系统按钮待 Xcode 和真机。当前实现原本未配置 secondaryButton，未新增或删掉稍后提醒功能。 |
| W08 | 去掉 Item 重复显式 unchecked Sendable，保留 SwiftData 宏的声明；模型访问仍由已有 ModelContext / MainActor 路径负责。弱引用先声明再赋值，仍等待对象释放并检查临时文件删除，没有改成强引用。 | Swift 6.2 对弱引用写法的独立编译检查和修改文件语法检查通过；SwiftData 宏、迁移/导入导出和 Jev 原生分享释放测试待 Xcode。 |
| W09 | 保留真实 AppIntents 提取，没有添加空依赖或关闭提取。主应用 ButlerAppIntents.swift 有实际意图；扩展源目录目前没有 AppIntent 声明。以下提供按 UDID 指定模拟器的命令。 | 源码审查完成；当前 orb 不含原始 ZIP 的构建命令/target 上下文，不能确认原元数据提示具体来自哪个 target。保留待归属核对，不宣称该提示一定无害。云端重复目的地提示保留待环境核对，不改后台工作流。 |

### W01 / W07 的框架依据

- Apple 的 [AVAudioConverter.convert 文档](https://developer.apple.com/documentation/avfaudio/avaudioconverter/convert%28to%3Aerror%3Awithinputfrom%3A%29)说明输入块为本次转换提供数据，方法返回时输出 buffer 长度就是已转换帧数。这是同步消费输入的转换接口，不是异步投递到 actor 的任务。兼容导入只在两个拥有此调用的文件中使用，不把 AVAudioPCMBuffer 声明为全局 Sendable；输入块只向本次转换供给一次缓冲区。
- analyzer converter 被 AudioRelay 的投递/回放锁保护；实时 converter 在 convert 全程加锁，PCM Data 创建后才离开锁。没有新增 unchecked Sendable；既有包装的共享状态现在有明确的串行保护。原生识别仍通过框架 AnalyzerInput 交付缓冲区，不把缓冲区捕获进自建 MainActor 任务。
- Apple 的 [新 Alert 初始化接口](https://developer.apple.com/documentation/alarmkit/alarmpresentation/alert-swift.struct/init(title:secondarybutton:secondarybuttonbehavior:))自 iOS 26.1 可用，明确由系统提供停止控件。全部相关 target 的部署下限为 26.2，所以直接使用该接口而不保留已弃用初始化。

### 本次实际执行的验证

- Linux orb 安装 Swift 6.2；无 Apple SDK / xcodebuild，也没有已连接的 Mac runner。
- `bash scripts/test-warning-core.sh`：**5 项测试，0 失败、0 跳过**；生产目标保留默认 MainActor，源文件及测试使用完整并发检查并将警告视为错误。脚本直接编译操作 codec 和日志 writer；从 Apple 依赖文件抽取未改动的纯值声明，仅替代未调用的应用日志路径。不覆盖 SwiftData 宏、ItemProfile 行为或整个 iOS 应用。
- `LC_ALL=C.UTF-8 TZ=America/Los_Angeles bash scripts/test-alarm-core.sh`：**157 项测试，0 失败、0 跳过**。这是 Linux 便携核心回归，不是原先 571 项英文美国区域的 iOS 全量回归，也不能与该基线直接相加。
- 修改的 Swift 文件通过 `swiftc -frontend -parse`；`.agents/setup` 的 plist / 资源元数据检查、shell 语法检查及 `git diff --check` 通过。已审查新增日志内容和并发访问，没有提交真实凭据。
- 新增 8 项回归测试，并扩展首次/后续动态上下文测试。其中上面 5 项已执行；音频并发 2 项、SwiftData 撤销保护 1 项及扩展后的订阅网络测试待 Apple 环境执行。

### W09 与剩余 Xcode 验收命令

在装有 Xcode 26.3 的 Mac 上先用 `xcrun simctl list devices available` 确认 iPhone 17 Pro 的 iOS 26.3 设备 UDID，将其填入 `UDID`；不要仅按设备名称匹配。结果路径须使用新的目录。

```bash
UDID='<已确认的 iPhone 17 Pro UDID>'
xcodebuild -project Butler.xcodeproj -scheme Butler \
  -destination "platform=iOS Simulator,id=$UDID" \
  -testLanguage en -testRegion US test \
  -resultBundlePath /tmp/Butler-warning-regression.xcresult
xcodebuild -project Butler.xcodeproj -scheme Butler -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/Butler-warning-check.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
```

第二条只验归档编译，不证明签名、Export 或 TestFlight 分发。须从两个完整日志按原始诊断逐项对照，并为保留元数据提示记录具体 target；有意图的 target 若跳过提取，必须继续修复而不能归为环境提示。没有在本次提交推送中启动 Xcode Cloud、修改工作流或发布 TestFlight。

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

### 2026-10-02 Build 33 测试失败修复

- 用户提供 Build 33 build-for-testing / test-without-building 日志；测试编译与归档通过，测试执行579项、1项跳过、3条失败断言。三个失败均属于 ChatDiagnosticsTests.testConcurrentAppendsKeepEveryCompleteLineExactlyOnce，并非三个独立缺陷。
- 原测试最多轮询约2秒就读取文件，云端当时仅完成370/401条。生产写入是utility串行异步队列，测试未与队列完成建立同步关系；不能把尚未写完直接解释成日志丢失，也不能靠无限增加固定延时验证完整性。
- 新增异步ChatDiagnostics.flush：在同一串行队列排入continuation，等待此前已提交的写入/轮转结束，不阻塞调用actor、不改变生产追加行为；三个日志测试读取前等待该屏障，保留完整行、数量、唯一性、中文轮转及错误保护断言。屏障不保证调用后新提交的写入已完成。
- SubscriptionModelTests的动态instructions/tools改由MainActor测试对象持有，稳定捕获引用，保留后续请求读取更新工具的断言；消除toolContext mutated after capture警告。
- Build 33日志确认AppIntents metadata skipped来自ButlerShareExtension，该扩展没有AppIntent，保留提示；模拟器多目的地提示属于环境，本机使用UDID消除歧义。
- 首次定向测试关闭签名，日志3项通过，但Keychain网络测试受签名环境阻塞。恢复正常签名后，本机Xcode26.3(17C519)、iOS26.2 iPhone17Pro模拟器、英文美国区域全量579项、1项既有跳过、0失败；动态上下文与全部日志测试通过，编译仅剩分享扩展元数据工具提示。结果/private/tmp/butler-build33-full.xcresult，日志/private/tmp/butler-build33-full.log。未执行真机交互验收，未启动云构建，本机结果不代替下次云端分发结果。
