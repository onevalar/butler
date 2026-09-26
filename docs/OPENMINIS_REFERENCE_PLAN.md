# Butler 借鉴 OpenMinis 的开发执行计划

状态：执行草案 v1  
最后更新：2026-07-26  
适用项目：Butler iOS  
参考项目：OpenMinis  
规范优先级：低于 `BUTLER_2_SPEC.md`，高于临时讨论、截图建议和旧 MVP 文档

## 0. 文档用途

本文把 Butler 可以从 OpenMinis 借鉴的设计模式转化为可执行的开发计划。它面向后续接手开发的 AI 和工程师，回答四个问题：

1. Butler 应该从 OpenMinis 学什么；
2. 哪些能力不应引入，或者暂时不应引入；
3. 每个阶段具体修改哪些文件、按照什么顺序实施；
4. 为什么必须按照这个顺序和边界实施。

本文不是新的产品事实来源。如果本文与 `BUTLER_2_SPEC.md` 冲突，必须以 `BUTLER_2_SPEC.md` 为准，并停止实现冲突部分。只有产品所有者明确确认后，才能先修改规范，再修改代码。

## 1. 执行摘要

Butler 的长期目标是成为越来越理解用户、能够处理越来越多生活事务的个人管家。物品管理是第一个切入领域，不是永久的产品边界。

OpenMinis 已经提供了通用 Agent、Provider、Memory、Skills、MCP、Shell、浏览器、文件和系统能力。Butler 应优先复用其中成熟且适配的实现，并在第一阶段用 Inventory 模块建立一套可靠的事实、行动和学习闭环。随着产品发展，这套 Core 应继续承载日历、提醒事项、家庭任务、健康、HomeKit、文件、浏览器和未来 Skills。

第一阶段的 Inventory 主链路继续保持：

```text
用户输入
  -> InventoryPlanProvider
  -> InventoryOperationPlan
  -> CatalogProductLookup / InventoryPlanSession
  -> InventoryPolicy
  -> 用户追问或确认
  -> InventoryRepository
  -> FieldEvidence + InventoryEvent
```

长期架构则应发展为：

```text
Butler Core
  -> Agent Orchestrator
  -> Capability Registry
  -> Permission Broker
  -> Context & Memory
  -> Model Providers
  -> Audit / Event History
  -> Domain Capabilities
```

OpenMinis 中暂时不进入第一阶段 Inventory 闭环的能力，不得被理解为永久禁止。它们应被标记为“按阶段启用”或“等待明确场景”，包括：

```text
Shell / iSH
浏览器自动化
通用文件写入
Markdown Memory
通用 Skills
MCP 生态
开放式多工具 Agent 循环
把 OpenMinis 的通用聊天产品形态整体设为 Butler 主界面
```

原则不是限制 Butler 能做什么，而是让每项新能力通过明确的 Capability、权限等级、数据范围和审计记录进入系统。能力可以持续增加，未经授权、无法解释和无法恢复的执行不能增加。

## 2. 当前代码事实

后续 AI 在开始任何阶段前，必须先确认下列事实仍然成立。如果代码已经变化，应更新本文的“执行状态”，不能机械按照旧文件名修改。

### 2.1 Butler 当前事实

1. 正常启动路径是 `ButlerApp -> ContentView -> DataManager -> DashboardView`。
2. 正常 Dashboard 仍通过 SwiftData `@Query` 读取旧 `Item`。
3. V2 输入只通过 Debug 参数 `--m2-input-harness` 进入。
4. M2 Harness 使用内存容器，不应写入正式数据库。
5. `InventoryInputCoordinator` 每次提交只调用一次 `InventoryPlanProvider`，后续追问通过冻结计划修订完成。
6. `InventoryPolicy` 已校验 schema version、字段证据、数量、revision 和高风险确认要求。
7. `InventoryRepository` 已负责事务写入、幂等 operation ID、revision、证据和事件。
8. `ButlerStore` 的 Schema 同时包含旧 Item 和 V2 模型。
9. Xcode 工程目前只有 Butler App Target，没有测试 Target。
10. 工程当前部署目标是 iOS 26.2；这只是当前工程事实，不是产品要求。最低系统版本不固定为 iOS 17 或 iOS 26，应在每个阶段根据实际采用的 Apple API、维护成本和覆盖范围选择“满足能力所需的最低版本”，并在引入更高版本 API 时记录理由。
11. `group.com.butler` 是正式 App Group ID；当前仍需补齐并验证 App、Share Extension 和 Widget 的 entitlements 接线。
12. Widget 已确认在产品规划中；源文件存在，但当前 Xcode 工程仍没有已确认的 Widget Target。
13. 尚未完成 Apple SDK 编译、SwiftData 旧库升级、模拟器、真机和 UI 回归门禁。

### 2.2 OpenMinis 当前参考事实

OpenMinis 中对 Butler 有参考价值的实现区域包括：

- `AgentToolDefinition`：集中声明模型可见工具及参数；
- Tool preflight：执行前校验必填参数；
- Provider abstraction：把模型供应商、凭据和协议差异隔离；
- Config confirmation gate：副作用执行前显示变更并等待用户决定；
- Offload permission dialog：展示动作名、参数和本次授权；
- Share Extension：通过 App Group 传递文本、URL、图片和文件；
- ShareCoordinator：处理冷启动、热启动、合并、消费和过期；
- QuickActionWorkflow：用显式状态机协调导航和相机/语音面板；
- Native Offloads：把日历、通知、提醒事项等系统 API 隔离成宿主能力；
- correlation logging：围绕工具调用、会话和后台状态记录诊断信息。

OpenMinis 中暂时不进入第一阶段 Inventory 闭环，但应为长期 Butler Core 保留复用路径的实现包括：

- iSH、PRoot 和 Shell 执行；
- 通用 Agent Chat Store；
- 通用 Memory、Skills 和 MCP；
- 文件系统 Workspace；
- 浏览器自动化；
- 与 OpenMinis 会话模型紧密耦合的聊天 UI。

这些能力的状态是“当前阶段暂缓”，不是“不允许采用”。出现明确用户场景后，应先评估直接复用 OpenMinis 现有模块，再决定适配范围。

## 3. 扩展原则和执行安全边界

以下条目用于保证 Butler 在能力和权限不断扩大时仍然可信。它们约束的是执行方式，不是产品功能上限。后续 AI 不得把第一阶段边界解释成永久禁止新增 Domain、Tool、Memory、Skill 或系统权限。

### 3.1 数据边界

本节首先适用于 Inventory 事实模块。未来其他 Domain 可以拥有自己的 Repository、Policy 和 Event，但必须遵守同样的职责分离思想。

1. 模型不得持有或接收 `ModelContext`。
2. 模型不得调用任意 SwiftData CRUD 接口。
3. 模型不得输出数据库字段名、Predicate、SQL 或持久化路径。
4. 所有写操作必须先成为 `InventoryOperationPlan`。
5. 所有计划必须经过 `InventoryPolicy`。
6. 所有持久化必须经过 `InventoryRepository` 或后续明确设计的同等级事务服务。
7. 业务状态、证据和事件必须在一次 save 中原子提交。
8. 已关闭批次、归档产品、stale revision 和 operation ID 冲突必须失败。

### 3.2 日期和药品边界

1. 模型估算日期不得写入 `packageExpiryDate`。
2. 包装有效期、药品字段和销毁操作必须明确确认。
3. 模糊日期不得静默补成精确日期。
4. “生产日期 + 保质期”只能生成候选或估算值，不能伪装成包装原文。
5. 日期字段必须保留来源、原文或图片证据。

### 3.3 AI 和网络边界

1. 大模型能力允许并预期联网使用；离线模式负责查看、本地语音输入、手动操作和可由本地规则完成的任务，不承诺离线运行大模型。
2. Butler 支持向用户选定的远程 Provider 上传文字、任务相关库存候选、语音、图片、小票和订单。首次配置 Provider 时必须清楚展示数据类别、用途、供应商和撤销入口；实际请求默认只发送完成当前任务所需的数据，以降低延迟、成本和无关暴露。
3. 用户提供 Provider 凭据。API Key 和 OAuth refresh/access token 必须进入 Keychain，不得进入 SwiftData、UserDefaults、日志或源码。
4. 供应商必须提供“不用于训练”的数据路径。OpenAI API 默认不使用 API 输入输出训练模型；若复用 ChatGPT Plus/Pro 登录路径，则必须同时检查并向用户说明 ChatGPT Data Controls，因为个人 ChatGPT 工作区的数据设置与 API 数据控制不是同一套机制。
5. Release 日志不得记录原始语音、完整小票、图片内容、完整库存和模型原始响应。
6. Provider 失败时不得降级为不受约束的自由文本解析。
7. 模型输出解码失败时不得尝试猜测数据库写入。
8. 用户关闭某个 Provider、撤销凭据或关闭某类上传后，后续任务必须立即停止使用对应网络能力，但本地查看和手动操作继续可用。

### 3.4 OpenMinis 代码复用原则

1. OpenMinis 已有实现满足 Butler 需求时，优先直接复用，避免重复造轮子。
2. 可以复用完整文件、类型、状态机、UI 组件或成组模块；应优先选择职责完整、依赖边界清晰的最小单元。
3. 复用前先识别依赖关系、线程模型、持久化假设、权限、资源文件和 Target 配置，避免只复制表面代码而遗漏运行条件。
4. 如果实现与 OpenMinis 其他系统高度耦合，应先尝试提取协议、适配器或必要依赖；只有提取成本明显高于重写，或者行为与 Butler 不兼容时，才重新实现。
5. 对复用代码的修改应尽量集中在 Butler Adapter 中，减少直接分叉，方便后续比较和吸收 OpenMinis 上游改进。
6. 每个复用任务应在开发日志中记录来源文件、复用范围、做过的适配、未带入的依赖和对应测试，方便后续维护。
7. 发布合规、署名和第三方声明作为发布流程处理，不得被用作禁止技术复用或要求重复实现的默认理由。

### 3.5 发布边界

1. 不得在没有 V2 正常读取路径时打开正式 V2 写入。
2. 不得在同一个阶段同时进行 SwiftData Schema 迁移、数据库 App Group 迁移和 Widget 接线。
3. 不得只通过静态检查就把 M0 至 M2 标记为可发布。
4. 新增模型、Share Extension 或通知快捷操作必须有 feature flag。
5. feature flag 默认关闭，直到对应验收项通过。

### 3.6 渐进权限模型

Butler 可以持续获得更多系统和数据权限。每个 Capability 必须声明权限等级、授权范围、持续时间和撤销方式。

| 权限等级 | 示例 | 推荐授权方式 |
|---|---|---|
| 读取和分析 | 查询库存、读取天气、读取日历空闲时间 | 用户启用 Capability 后可自动执行 |
| 可逆写入 | 创建提醒、加入购物清单、移动库存位置 | 支持单次、会话或长期授权 |
| 敏感写入 | 修改日历、记录健康信息、控制家庭设备 | 首次明确说明，按风险再次确认 |
| 破坏或高风险 | 删除数据、药品处理、购买、发送外部消息 | 每次确认并记录审计事件 |

权限系统必须支持：

- 单次允许；
- 当前会话允许；
- 对指定 Capability 长期允许；
- 仅允许读取；
- 随时撤销；
- 查看 Butler 最近使用过哪些权限；
- 为自动化规则设置金额、时间、对象和频率范围；
- 高风险动作即使有长期授权仍可要求再次确认。

更多权限是 Butler 发展的正常方向。Permission Broker 的目的不是减少能力，而是让用户可以放心地授予更多能力。

## 4. OpenMinis 能力采用矩阵

| OpenMinis 能力 | Butler 决策 | Butler 中的形式 | 原因 |
|---|---|---|---|
| Tool Definition | 优先复用并领域化适配 | 只读查询工具和计划生成工具 | 复用成熟的工具声明与预检结构，但收窄模型权限 |
| Tool Preflight | 借鉴并收紧 | Schema、必填字段、类型和范围校验 | 模型输出不稳定，需要执行前阻断 |
| JSON 自动修复 | 只采用低风险部分 | 传输重试和安全字符串规范化 | 模糊修复日期、身份和药品字段会制造错误事实 |
| Concurrent Tools | 分阶段启用 | 首期写入顺序执行；只读和互不依赖的 Capability 可并发 | 复用并发执行能力，同时保持有依赖动作的顺序 |
| Provider Factory | 首期简化、长期完整复用 | `InventoryModelClient` 先接一个 Provider，Butler Core 后续支持多 Provider 路由 | 第一阶段控制复杂度，长期不限制模型选择 |
| Offload Permission | 借鉴交互模式 | `SystemActionAuthorizationCoordinator` | 用户应看到系统动作和影响范围 |
| Config Confirmation Gate | 借鉴队列和 UI | 使用现有 `TrustedInventoryConfirmation` | Butler 已有更严格的字段级确认凭据 |
| Share Extension | 高优先级借鉴 | `PendingCapture` 队列和 App Group 文件转移 | 图片、小票、订单是 Butler 的核心输入 |
| 300 秒临时 Share Buffer | 修改后采用 | 持久 PendingCapture；未处理和失败记录无限期保留并提醒 | 用户明确表达的录入意图不能因 TTL 或固定天数静默丢失 |
| Quick Action Workflow | 高优先级借鉴 | `CaptureLaunchWorkflow` 显式状态机 | SwiftUI 导航、冷启动和相机呈现容易竞态 |
| Native Offloads | 借鉴分层 | Notification、Reminder、Widget Action Adapter | 系统 API 不应散落在模型或业务层 |
| Markdown Memory | 分层采用 | 库存事实保持结构化，同时复用偏好、上下文和程序性记忆 | 不同类型的记忆承担不同责任 |
| Skills / MCP | 长期 Butler Core 能力 | 第一阶段预留接口，出现场景后优先复用 OpenMinis 实现 | 支撑未来快速增加生活事务能力 |
| iSH / Shell | 未来可选高权限 Capability | 在沙箱、权限和审计下按需启用 | 文件处理、自动化和高级任务可能需要真实执行环境 |
| Browser Automation | 未来信息与事务 Capability | 订单导入先走分享，研究、比价和网页事务可按需启用 | 不封死未来的主动管家能力 |
| 通用聊天 UI | 按需复用组件 | 复用输入、附件、语音、消息和流式状态组件，组合成任务型审核流程 | 复用成熟组件，同时保持 Butler 的库存任务重心 |

## 5. 目标架构

### 5.1 总体数据流

```text
                         Butler Core
 ┌───────────────────────────────────────────────────────────────┐
 │ Agent Orchestrator                                            │
 │ Capability Registry                                           │
 │ Permission Broker                                             │
 │ Context & Multi-layer Memory                                  │
 │ Model Provider Router                                         │
 │ Audit / Event History                                         │
 │ Background Work / Action Scheduling                           │
 └───────────────────────────────────────────────────────────────┘
             |                 |                    |
             v                 v                    v
       Inventory         Calendar/Tasks       Future Capabilities
       Shopping          Home/Health          Skills / MCP
       Receipts          Files/Browser        Shell Workspace
```

Inventory 是第一个 Domain Capability，内部继续使用严格的数据流：

```text
CaptureEnvelope
  -> preprocessing
  -> InventoryPlanProvider
  -> strict plan decoder
  -> CatalogProductLookup / InventoryPlanSession
  -> InventoryPolicy
  -> clarify / confirm / reject
  -> InventoryRepository
  -> FieldEvidence + InventoryEvent + ActionOutbox
```

### 5.2 Inventory 分层职责

| 层 | 可以做什么 | 不可以做什么 |
|---|---|---|
| Capture Adapter | 接收输入、复制附件、记录来源 | 理解业务或写库存 |
| Preprocessor | 语音转写、OCR、条码、确定性日期候选 | 决定最终库存事实 |
| Plan Provider | 把输入转换为白名单操作计划 | 访问 SwiftData 或确认自己的推断 |
| Plan Decoder | 校验协议结构和版本 | 修复高风险语义错误 |
| Product Lookup | 本地匹配已有产品候选 | 自动合并产品 |
| Policy | 决定执行、追问、确认或拒绝 | 写数据库 |
| Review UI | 收集用户直接命令和确认 | 伪造 confirmation receipt |
| Repository | 原子写入业务状态、证据和事件 | 调用模型或呈现 UI |
| Action Adapter | 调用 Apple 系统 API | 改库存事实 |

### 5.3 Butler Capability Contract

建议为所有未来能力定义统一协议。实际签名可在 Butler Core 阶段结合复用的 OpenMinis 类型确定。

```swift
protocol ButlerCapability {
    var identifier: String { get }
    var displayName: String { get }
    var requiredPermissions: [ButlerPermission] { get }
    var tools: [ButlerToolDefinition] { get }

    func preflight(_ request: ButlerToolRequest) async throws
    func execute(_ request: ButlerToolRequest) async throws -> ButlerToolResult
}
```

每个 Capability 必须声明：

- 模型可见的工具；
- 可读取和可写入的数据范围；
- 权限等级；
- 是否可并发；
- 是否可撤销；
- 是否需要用户在场；
- 日志脱敏规则；
- 失败恢复和幂等策略；
- 是否允许后台运行；
- 是否支持长期自动化授权。

Inventory 可以先通过 Adapter 接入该协议，不需要为了通用化重写现有 Repository 和 Policy。

## 6. 新增核心数据契约

以下名称是建议名称。实施时如需调整，必须保持职责不变，并在本文记录最终名称。

### 6.1 CaptureEnvelope

建议新文件：`Butler/Domain/CaptureEnvelope.swift`

建议字段：

```swift
struct CaptureEnvelope: Codable, Sendable, Identifiable {
    let id: UUID
    let createdAt: Date
    let source: CaptureSource
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let referenceDate: Date
    let textSegments: [CaptureTextSegment]
    let attachments: [CaptureAttachment]
    let consentSnapshot: CaptureConsentSnapshot
    let deduplicationKey: String?
}
```

设计原因：

- 所有输入先变成同一种不可变结构，Provider 不需要理解 UI 生命周期；
- `referenceDate` 必须冻结，避免“下周”在重试时产生不同结果；
- locale 和 time zone 必须随输入保存，避免日期解析依赖当前设备状态；
- consent snapshot 记录本次允许上传什么，不能只读取可能已经变化的 Settings；
- deduplication key 用于处理 Share Extension 重复交付。

### 6.2 CaptureAttachment

建议字段：

```swift
struct CaptureAttachment: Codable, Sendable, Identifiable {
    let id: UUID
    let kind: CaptureAttachmentKind
    let relativePath: String
    let uniformTypeIdentifier: String
    let originalFilename: String?
    let byteCount: Int64
    let sha256: String
    let createdAt: Date
}
```

约束：

- 只保存受控根目录下的相对路径；
- 拒绝 `..`、符号链接逃逸和根目录外文件；
- Share Extension 必须先复制 security-scoped 文件，再结束访问；
- 文件大小和 UTType 必须在进入 OCR 或上传前校验；
- 主 App 成功接管后，应把文件移动到主 App 管理的证据目录；
- App Group 中只保留传输副本，不作为长期事实存储。

证据保留决策：

- 主 App 管理的原始图片、PDF、小票和订单证据默认长期保留，不设置自动过期时间；
- 证据元数据、hash、来源、引用关系和同步状态进入结构化存储；
- 本地文件是可离线访问的第一份副本，后续优先增加 iCloud 私有同步；大文件使用 CloudKit 私有数据库中的 `CKAsset` 或等价的私有 iCloud 文件方案，不把 App Group transfer 目录当同步目录；
- 用户删除单张证据、整个 Capture 或关联业务记录时，先检查引用关系并明确展示影响；
- 只有无引用的 App Group 传输副本和确定完成的临时派生文件可以自动清理。

### 6.3 PendingCapture

OpenMinis 使用单个临时 `PendingShare`。Butler 应改成持久队列：

```swift
enum PendingCaptureState: String, Codable {
    case pending
    case claimed
    case planned
    case imported
    case failed
    case discarded
}
```

每条记录必须拥有稳定 capture ID、状态、失败原因和更新时间。显式分享是用户已经表达的录入意图，不应因为 300 秒 TTL 静默删除。

保留和清理策略：

- `pending` 和 `failed` 无限期保留，直到用户完成处理或明确丢弃；
- 对长期未处理内容进行温和提醒，提醒频率可配置并可暂停，不能以提醒失败或时间经过为由删除；
- `claimed` 超时后回到可恢复状态，不能被当成已完成；
- `imported` 和用户明确 `discarded` 后，只有已经进入主 App 长期证据目录或确认不再需要的 App Group 传输副本可以清理；
- 主 App 长期证据默认持续保留，并优先支持 iCloud 私有同步；
- 清理前必须确认文件不再被任何 PendingCapture、CaptureAttachment、FieldEvidence 或其他 Domain 引用；
- 不允许固定 7 天、30 天等自动删除用户录入意图的策略。

### 6.4 Inventory Tool Contract

首期只允许两类工具。

只读工具：

```text
inventory.searchProducts
inventory.listLots
inventory.listExpiringLots
inventory.getLot
inventory.getRiskSummary
```

计划工具：

```text
inventory.planInput
inventory.proposeQuantityAdjustment
inventory.proposeLotClosure
inventory.proposeMove
inventory.proposeDateChange
```

禁止工具：

```text
inventory.executeRaw
inventory.deleteDatabaseRecord
inventory.mergeProductsAutomatically
inventory.writeField
inventory.runPredicate
inventory.runSQL
```

所有“propose”工具只返回计划或确认要求，不执行写入。真正执行只能由可信 UI 边界调用 Repository。

### 6.5 SystemAction

建议把通知、提醒事项和 Widget 刷新定义成宿主动作：

```swift
enum SystemActionKind: String, Codable {
    case scheduleExpiryNotification
    case cancelExpiryNotification
    case createReminder
    case refreshWidgets
}
```

库存事务和系统动作不能简单混在一起。推荐使用 Outbox 模式：

```text
同一 SwiftData save:
  修改 InventoryLot
  追加 InventoryEvent
  追加 PendingSystemAction

save 成功后:
  SystemActionWorker 执行系统动作
  标记 action 已完成或可重试失败
```

原因是 Apple 系统 API 可能失败、延迟或要求授权。若先发通知再保存库存，保存失败会留下错误通知；若先保存库存但没有持久 action，App 崩溃后会永久漏掉通知。

`PendingSystemAction` 确定进入 SwiftData，使业务事实、事件和 Outbox 可以在同一次 save 中原子落盘。新增模型会改变 Schema，因此必须单独经过 M0 兼容测试，不能和 App Group 数据库迁移同时做。

## 7. 模型 Provider 设计

### 7.1 保留 Butler 领域协议，直接复用 OpenMinis Provider 实现

Butler 已经拥有正确的业务抽象：

```swift
protocol InventoryPlanProvider {
    func plan(for input: InventoryPlanningInput) async throws -> InventoryOperationPlan
}
```

该领域协议继续保留，但其下方应优先直接复用 OpenMinis 已有的 Provider、OAuth、流式响应和 wire-format 实现，通过 Adapter 接到 Butler：

```text
InventoryPlanProvider
  -> LocalInventoryPlanProvider
  -> RemoteInventoryPlanProvider
       -> InventoryModelClient
            -> ProviderAdapter
```

职责：

- `RemoteInventoryPlanProvider` 负责构造 Butler 领域提示和严格 schema；
- `InventoryModelClient` 负责超时、HTTP、重试、状态码和取消；
- `ProviderAdapter` 只负责供应商 wire format；
- OpenMinis Provider 负责已经成熟的 OAuth/API 请求、响应流和供应商协议；
- API Key 与 OAuth token 存取由独立 Keychain 服务负责。

领域协议与代码复用不冲突。保留 `InventoryPlanProvider` 是为了不让通用 Agent 直接越过 `InventoryPolicy` 和 `InventoryRepository`；直接复用 OpenMinis Provider 是为了避免重新实现认证、网络协议和流式解析。

### 7.2 首发 OpenAI 双路径和后续 Provider 扩展

首发优先支持 OpenAI，并采用两条并存路径：

1. 实验路径：直接复用 OpenMinis 的 `CodexOAuthManager.swift` 和对应 OpenAI/Codex Provider，实现用户使用 ChatGPT 账户登录的技术验证。
2. 稳定路径：用户提供 OpenAI API Key，使用官方 API 和独立 API 计费。
3. 两条路径都挂在同一 `InventoryPlanProvider` 和 `ProviderAdapter` 之后，不改变 Butler 的 schema、Policy、审核和 Repository。
4. 设置页优先展示可用且已经验证稳定的路径；OAuth 实验路径用 feature flag 控制，验证通过后再提升为正式选项。
5. Butler 长期继续复用 OpenMinis 的多 Provider、模型能力识别和路由实现，并允许增加用户选择的其他供应商。

原因：

- OpenMinis 已经证明 ChatGPT/Codex OAuth 路径在其产品内有可运行实现，值得直接复用和验证；
- OpenAI 官方当前仍把 ChatGPT 订阅与通用 API 计费分开，不能仅凭 Plus/Pro 订阅就承诺第三方 iOS App 一定拥有通用模型额度；
- 因此 OAuth 路径的目标是积极验证并尽可能使用订阅能力，不是预先禁止；API Key 是在账户资格、端点、限额或稳定性不满足时保证 Butler 可用的后备；
- 首次验证必须覆盖真实 Plus/Pro 账户、免费账户、token 刷新、退出登录、限流、模型可用性、structured output、图像输入、后台恢复和错误提示；
- 用户凭据始终由用户提供，Butler 首期不建设统一服务端代理。

截至 2026-07-26 的官方参考：

- ChatGPT Plus/Pro 包含 Codex 使用资格：<https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan>
- ChatGPT 与 API Platform 采用分离的计费系统：<https://help.openai.com/en/articles/9039756-billing-settings-in-chatgpt-vs-platform>
- OpenAI API 数据默认不用于训练：<https://help.openai.com/en/articles/10306912-sharing-feedback-evals-and-api-data-with-openai>

### 7.3 输入最小化

用户允许 Butler 在任务需要时上传文字、库存候选、语音、图片、小票和订单。默认采用任务相关数据最小化，不是因为禁止上传，而是为了更流畅、更低成本并减少无关上下文。推荐两段式流程：

```text
阶段 1:
  发送本次输入和完成任务需要的附件
  生成产品与批次候选

阶段 2:
  在本地使用 CatalogProductLookup 匹配已有产品
  只在确有歧义时，发送相关候选摘要
```

任何请求都不得发送：

- 整个 SwiftData 数据库；
- 所有历史 InventoryEvent；
- 不相关物品；
- 用户没有选择的相册内容；
- API Key、设备路径和内部数据库 ID。

内部 UUID 可在本地计划修订阶段生成。模型没有必要看到真实持久化 ID。

### 7.4 输出校验和修复等级

借鉴 OpenMinis preflight，但采用更严格的分级。

允许自动处理：

- 去除字符串首尾空白；
- 标准化明确的中文数字；
- 把已知单位同义词映射到标准单位；
- 网络 408、429、5xx 在未收到完整响应时重试一次；
- JSON 被截断时重新请求模型一次，并要求重新输出完整对象。

不得自动修复：

- 包装有效期；
- 药品名称、剂量和安全字段；
- 产品身份合并；
- 批次状态；
- expectedRevision；
- operation ID 冲突；
- 不存在的 entity ID；
- 模糊日/月顺序；
- 把任意字段类型强制转成字符串后继续执行。

模型重试不得重用旧 confirmation receipt。计划内容或 revision 变化后，旧 receipt 必须失效。

### 7.5 默认超时和重试

建议首期默认值：

- 普通文字规划超时：30 秒；
- 图片规划超时：60 秒；
- 传输级自动重试：最多 1 次；
- 用户取消：立即取消网络任务，丢弃未完成响应；
- Repository 执行：绝不由网络重试触发；
- 失败后保留 CaptureEnvelope，允许用户手动重试或改用本地流程。

这些值应集中在 `InventoryPlanningConfiguration`，不要散落 magic number。

## 8. UI 设计

### 8.1 第一阶段任务型入口，长期支持统一管家界面

Dashboard 与对话长期并存，不把 Butler 收缩成单一聊天应用，也不把对话限制在独立首页。每个主要页面都应提供快速开始对话的入口，并自动携带当前页面、选中对象和允许的数据上下文。第一阶段仍围绕 Dashboard、风险和行动建立可信闭环，随后把库存、家庭任务、购物、日历、健康和自动化汇总到统一的对话与行动体验。

建议任务型流程：

```text
Input Composer
  -> Planning Progress
  -> Clarification Card
  -> Product Match Card
  -> Plan Review Card
  -> Confirmation Requirements
  -> Execution Result
```

第一版可以暂不接入：

- Token 级流式文字；
- Agent 思考消息列表；
- Tool Call 展开器；
- Session Memory 管理页面；
- Skill 管理页面；
- Shell 和浏览器结果组件。

这些组件不是永久排除。后续出现真实场景时，应优先复用 OpenMinis 的消息、附件、流式输出、工具结果、Memory、Shell 和 Browser UI，再通过 Butler 的 Capability 与 Permission 层接入。

全局对话入口建议采用可复用的 `ButlerConversationLauncher`：

- Dashboard、详情页、Capture Inbox、购物清单、家庭任务、日历和健康页使用同一入口；
- 启动时生成 `ConversationContextSnapshot`，只引用当前对象和页面能力，不复制整个数据库；
- 用户可以在发送前查看并移除附件或上下文；
- 对话中的写操作仍转成 Domain Plan 并进入对应审核/权限流程；
- 对话界面直接复用 OpenMinis 的输入框、附件、语音波形、消息列表和流式状态组件，再替换会话 Store 与工具卡片 Adapter。

### 8.2 审核卡必须展示

每个批次至少展示：

- 产品名称、品牌和规格；
- 新产品或已有产品；
- 数量和单位；
- 三类日期的独立标签；
- 储存位置；
- 每个推断字段的来源；
- 需要确认的高风险字段；
- 原始文本或图片证据入口；
- 修改入口；
- 最终确认按钮。

“确认并添加”必须是可信 UI 事件。模型不能在自己的 JSON 中设置 confirmed。

### 8.3 快捷入口状态机

优先抽取和复用 OpenMinis QuickActionWorkflow 的状态机实现；通过 Butler Adapter 替换会话、导航和相机目标：

```text
idle
  -> requestReceived(mode, captureID?)
  -> ensuringRootVisible
  -> awaitingCaptureViewMount
  -> presentingInput
  -> active
  -> completed / cancelled / failed
  -> idle
```

每次入口必须绑定稳定 workflow ID。不要依赖多个 `DispatchQueue.asyncAfter` 猜测 SwiftUI 页面何时挂载。

适用入口：

- Home Screen Quick Action；
- Widget；
- App Shortcut / Siri；
- Share Extension；
- Spotlight；
- 通知快捷操作；
- 自定义 Deep Link。

Deep Link 中不得携带完整小票、库存内容或 API Key。只携带 mode 和本地 capture ID。

## 9. Share Extension 和多模态流程

### 9.1 Share Extension 接收范围

第一版目标接收：

- plain text；
- http/https URL；
- image；
- PDF，在 OCR/解析质量基准达标时正式开启，否则保留在 Inbox 供用户查看和手动处理；
- 通用文件，限定允许 UTType 和大小。

第一版不接收：

- 视频；
- 可执行文件；
- 任意目录；
- 超大压缩包；
- 未知二进制格式。

OpenMinis 支持视频是因为它是通用 Agent。Butler 第一阶段没有视频库存输入需求，不应扩大攻击面和存储成本。

外部输入还应规划：

- 电商订单网页分享；
- 订单截图和商品图片识别；
- 邮件正文、附件和转发内容导入；
- 条码扫描与外部商品目录查询。

这些输入全部先进入 Capture Inbox，保存来源证据并生成候选，不直接修改库存、购物或日历事实。

### 9.2 Share 处理顺序

```text
Share Extension:
  1. 验证 UTType 和文件大小
  2. 为每次分享生成 capture ID
  3. 复制附件到 App Group transfer/<captureID>/
  4. 计算 hash
  5. 原子写入 PendingCapture metadata
  6. 打开 butler://capture?id=<captureID>

Main App:
  7. CaptureLaunchWorkflow 接收 ID
  8. PendingCaptureStore claim，防止重复消费
  9. 验证路径、hash 和附件存在
  10. 移入主 App 管理目录
  11. 构造 CaptureEnvelope
  12. 本地 OCR / 条码 / 日期候选
  13. 进入统一规划和审核
  14. 成功后清理 App Group 传输副本
```

原子写入可采用“临时文件写完后 rename”的方式，避免 Extension 被系统终止时留下半个 JSON。

### 9.3 多模态解析顺序

```text
Apple Vision / VisionKit 本地 OCR
  -> 本地条码识别
  -> 本地 DateParser 生成候选
  -> 本地规则提取生产日期、保质期和储存词
  -> 如果信息不足且用户允许，调用多模态 Provider
  -> 生成字段候选和证据
  -> 用户审核
```

本地解析器应继续存在，原因：

- 离线可用；
- 快速且成本低；
- 可作为模型失败后的 fallback；
- 包装日期可用确定性规则进行交叉检查；
- 能减少上传数据。

多模态模型必须返回候选，不得直接补全事实。推荐额外返回字段对应的 OCR 原文片段。若未来保存图片坐标或裁剪区域，需要先扩展 `FieldEvidence` 或新增证据附件模型，并完成 Schema 兼容测试。

### 9.4 日期精度

当前决策采用候选模式：模糊日期只保存在待确认候选和证据中，不写入 `InventoryLot` 的精确日期字段。后续如果高频场景证明需要“月份级日期”，再新增日期精度模型；在此之前不得擅自把 `2026-08` 写成 `2026-08-01` 或月末。

### 9.5 外部商品目录

外部商品目录采用 Provider 抽象和本地私有缓存：

```swift
protocol ProductCatalogProvider {
    func lookup(barcode: String, locale: Locale) async throws -> CatalogCandidate?
}
```

执行规则：

- 条码本地识别后才调用目录 Provider；
- 优先支持无需凭据或用户可自行提供凭据的目录；凭据进入 Keychain；
- 缓存只保存条码对应的公开商品身份、规格、来源、抓取时间和响应版本，不上传或共享用户库存；
- 默认使用 30 天刷新窗口和 stale-while-revalidate：缓存命中可立即显示，同时后台刷新；用户手动修改的字段永远优先；
- 外部结果始终是带来源的候选，不自动合并 Product，不覆盖包装图片或用户确认事实；
- 每个 Provider 必须有授权说明、速率限制、失败回退和清除缓存入口；
- 如果目录覆盖率、合法可用性或识别准确率不足，则保留条码作为证据并让用户手动确认，不伪装成已支持。

30 天是公开商品元数据的性能默认值，不是用户数据保留期限；后续可根据实际 Provider 的更新频率调整。

## 10. 系统动作和通知

### 10.1 借鉴 Native Offload 的分层，不借鉴 CLI 形式

OpenMinis 把系统 API 包装成可从 Shell 调用的 offload。Butler 应优先复用其中成熟的权限、参数校验和 Apple API 调用代码，并在外层增加 Swift protocol；如果 Butler 不需要 CLI，只移除或隔离 CLI 注册层：

```swift
protocol SystemActionExecutor {
    func execute(_ action: PendingSystemAction) async throws
}
```

具体适配器：

- `NotificationActionExecutor`；
- `ReminderActionExecutor`；
- `WidgetRefreshActionExecutor`。

### 10.2 权限请求

当前 Butler 启动时会主动请求通知权限。建议改为渐进授权：

1. 用户第一次启用提醒时解释用途；
2. 再调用系统授权；
3. 拒绝后保留库存功能；
4. 设置页显示当前授权状态和跳转入口；
5. 不循环弹系统授权。

原因是启动即请求通常缺少上下文，会降低授权率，也不符合 Butler“提醒连接行动”的产品逻辑。

### 10.3 通知快捷操作

建议首期动作：

- 查看批次；
- 稍后提醒；
- 标记用尽；
- 标记丢弃。

“标记用尽”和“标记丢弃”是直接用户命令，但仍必须：

- 使用 lot ID，不使用名称猜测；
- 带 expectedRevision；
- 经过 Policy；
- 追加 InventoryEvent；
- 幂等处理重复通知回调；
- 在 stale revision 时打开 App 让用户重新确认。

确认策略按风险和歧义决定：

- 查看和稍后提醒不需要确认；
- “标记用尽”在 lot 唯一、expectedRevision 有效、不是药品且提供可撤销入口时可直接执行，不再增加第二次确认；
- 多个合理批次、数量含糊、revision 过期或涉及敏感物品时打开 App 审核；
- “标记丢弃”、药品处理和不可逆动作继续要求明确确认。

这使低风险高频操作足够流畅，同时不把所有通知动作粗暴地归为同一风险等级。

## 11. 多层记忆和结构化学习

Butler 要成为越来越懂用户的管家，必须拥有长期记忆。正确做法不是在结构化数据和通用 Memory 之间二选一，而是区分记忆类型。

长期记忆默认开启。首次使用时应以简短、可理解的方式说明 Butler 会记住什么、用于什么，并持续提供查看、编辑、删除、暂停和按类型关闭的入口。默认开启不等于无限制记录：敏感 Domain 仍遵守系统权限、Provider 上传选择和对应数据最小化。

```text
事实记忆
  InventoryLot、Calendar Event、Reminder 等领域事实
  使用结构化存储、证据、revision 和事件

偏好记忆
  常买品牌、提醒时间、沟通方式、常用地点
  用户可查看、编辑和删除

习惯记忆
  消耗周期、购物频率、家庭规律
  从历史行为中生成建议，经用户确认后生效

对话记忆
  最近目标、上下文和未完成讨论
  可复用 OpenMinis Session / Markdown Memory 机制

程序性记忆
  “以后遇到这种情况怎么做”
  可发展为规则、自动化、Skills 或 MCP 配置
```

库存事实不能只存在于自由文本 Memory，但自由文本 Memory 可以为对话、偏好和程序性知识服务。后续应优先评估复用 OpenMinis 的 Memory Store、Session Memory UI 和 Skill Store。

可学习内容：

- 常购数量和单位；
- 常用储存位置；
- 提醒提前量；
- 复购阈值；
- 消费周期；
- 用户明确确认的产品别名。

Inventory 事实层不可自动学习：

- 包装有效期；
- 药品剂量；
- 产品合并；
- 用户只修正过一次且存在歧义的值；
- 从模型推断但用户没有确认的字段。

M4 第一版只生成 `TemplateSuggestion`，用户确认后才更新 `PersonalProductTemplate`。`TemplateSuggestion` 确定作为 SwiftData 持久化模型，至少包含来源事件、候选变更、状态、创建时间、最后展示时间、拒绝原因和应用事件 ID。持久化可以避免重启丢失建议、重复轰炸用户，并支持跨设备同步与审计；不要在后台静默修改正式模板。

建议学习条件：

```text
至少有一次明确 userEdited 或 userConfirmed
  -> 生成建议
  -> 用户确认
  -> updateTemplate operation
  -> Repository 写入
  -> templateUpdated event
```

## 12. 日志、诊断和指标

优先复用 OpenMinis 可解耦的 correlation logging、脱敏和 category 组织代码；通过 `ButlerLogger` 适配 Butler 的 ID 和业务字段，底层继续使用 `Logger` / OSLog。

建议 category：

```text
capture
speech
vision
planning
policy
repository
migration
systemAction
notification
privacy
```

每条相关日志尽量包含：

- inputID；
- captureID；
- planID；
- operationID；
- actionID；
- 状态和耗时；
- 错误类型。

Release 日志不得包含：

- 原始用户句子；
- 商品完整清单；
- 图片；
- OCR 全文；
- API Key；
- 模型完整响应；
- App Group 绝对路径。

诊断数据决策：

- 默认保存脱敏诊断元数据：Provider、模型、状态码、错误类别、耗时、重试次数、schema 校验结果、token/用量统计和 correlation ID；
- 默认不保存模型原始响应，也不把原始响应写入 OSLog、分析系统或 iCloud；
- Debug 诊断模式可由用户或开发者显式开启，原始响应仅加密保存在本机受保护目录，默认 24 小时后删除，并提供立即清除入口；
- 诊断导出前再次预览和脱敏，用户主动选择是否分享；
- 若错误可通过 hash、字段路径和校验错误定位，就不保存原文。

建议指标：

- 规划耗时；
- 一次成功率；
- 追问次数；
- 用户纠正率；
- 远程 Provider 失败率；
- OCR 候选接受率；
- share 到完成入库的耗时；
- 通知后的处理率；
- stale revision 发生次数；
- 计划被 Policy 拒绝的原因分布。

指标首期只保存在本地。是否上传分析数据必须单独决定。

## 13. 分阶段开发执行计划

每个工作包必须独立完成、验证和记录。不要把多个阶段合并成一个大改动。

### 阶段 A：建立 Apple 平台验证基线

目标：证明当前 M0 至 M2 源码在真实 Apple 工具链下成立。

为什么先做：

- 当前没有 Tests Target；
- V2 Schema、Predicate、SwiftData migration 和 actor isolation 尚未经过 Apple SDK；
- 在未知基线上接入云模型、Share Extension 或新 Schema，会让失败原因无法定位。

修改范围：

- `Butler.xcodeproj/project.pbxproj`
- 新建 `ButlerTests/`
- 测试 fixtures
- `DEVELOPMENT_LOG.md`

执行步骤：

1. 新增 `ButlerTests` Unit Test Target，只依赖 Butler App Target。
2. 为旧 Item-only Schema 创建固定临时数据库 fixture。
3. 使用 `ButlerStore.schema` 打开同一数据库。
4. 验证旧字段逐行不变，V2 表为空。
5. 为 `InventoryPolicy` 添加协议版本、负数量、非法 confidence、包装日期确认、销毁确认测试。
6. 为 `InventoryRepository` 添加原子事务、幂等重放、operation ID 冲突、stale revision 和 rollback 测试。
7. 为 `LegacyItemMigrator` 添加首次导入、重复导入、失败回滚和不自动合并测试。
8. 为 M2 默认中文句子添加 Provider、Session revision、确认和最终执行测试。
9. 编译 Debug 和 Release。
10. 验证 Release 无法进入 `--m2-input-harness`。
11. 把 Xcode 版本、SDK、模拟器/设备和结果写入 `DEVELOPMENT_LOG.md`。

验收：

- `BUTLER_2_SPEC.md` 8.2 至 8.5 对应项目全部通过；
- 没有为了让测试通过而打开正常 V2 写入口；
- 数据库打开失败时没有删除或静默重建；
- 测试使用临时目录或内存容器，不接触用户数据库。

停止条件：

- Schema 无法兼容旧数据库；
- `@Model` 或 `#Predicate` 在 Apple SDK 编译失败；
- Repository 无法保证回滚；
- App Group 配置与当前数据库位置不一致。

出现停止条件时，只修复基线，不进入阶段 B。

### 阶段 B：建立 V2 正常读取与受控生产入口

目标：让 V2 写入的数据能在正常 UI 中被看到和管理，再考虑更强 AI。

为什么：

当前 M2 写入被隔离，是为了避免新批次写入后在旧 Dashboard 中不可见。若没有 V2 读取路径，任何更智能的录入都会制造“数据库里有、用户界面里没有”的隐形库存。

建议新增：

- `Butler/Persistence/InventoryReadRepository.swift`
- `Butler/Services/V2InventoryDashboardModel.swift`
- `Butler/Views/Dashboard/V2DashboardView.swift`
- `Butler/Services/ButlerFeatureFlags.swift`

建议修改：

- `ContentView.swift`
- `SettingsView.swift`
- `DEVELOPMENT_LOG.md`

执行步骤：

1. 建立只读 V2 repository，返回 DTO，不把 SwiftData Model 暴露给模型层。
2. 实现 V2 Dashboard 最小读取路径：产品、批次、状态、数量和三类日期。
3. 增加 Debug-only feature flag 切换旧 Dashboard 和 V2 Dashboard。
4. 提供显式旧数据迁移开发入口。
5. 迁移前显示数量和不可撤销影响；迁移失败显示错误，不吞错。
6. 迁移后继续保留旧 Item。
7. 在 V2 UI 可见、详情可打开、状态操作可用后，再考虑生产 V2 输入。
8. 第一次生产启用仍使用本地 Provider，不同时接入云模型。

验收：

- V2 新批次在正常 UI 可见；
- V2 详情可以显示证据和事件；
- 旧 Item 未丢失；
- 重复迁移不重复创建；
- feature flag 关闭时旧路径不受影响。

### 阶段 C：统一 Capture 管线

目标：把现有文字、语音和未来分享/图片入口统一成 `CaptureEnvelope`。

为什么：

如果每个入口分别调用 NLP、Provider 和 Repository，后续会出现不同的日期语义、隐私策略和确认行为。统一 Capture 是借鉴 OpenMinis 多入口能力时最重要的内部接口。

建议新增：

- `Butler/Domain/CaptureEnvelope.swift`
- `Butler/Services/Capture/CaptureCoordinator.swift`
- `Butler/Services/Capture/CapturePreprocessor.swift`
- `Butler/Services/Capture/CaptureLaunchWorkflow.swift`
- `Butler/Persistence/PendingCaptureStore.swift`

建议修改：

- `VoiceInputView.swift`
- `V2InventoryInputView.swift`
- `InventoryInputCoordinator.swift`

执行步骤：

1. 定义不可变 Capture 数据契约。
2. 让文字输入先构造 CaptureEnvelope，再转换成 `InventoryPlanningInput`。
3. 让语音只负责生成 transcript 和语音 evidence，不直接调用库存写入。
4. 冻结 referenceDate、locale 和 time zone。
5. 加入 cancellation 和明确状态：idle、preprocessing、planning、clarifying、reviewing、executing、completed、failed。
6. 保持 Provider 每次 submit 只调用一次；追问修订冻结计划。
7. 为重复 inputID 和 captureID 添加幂等测试。

验收：

- 旧默认 M2 中文句子结果不变；
- 文字和语音走相同规划路径；
- 取消后没有写入；
- 重试不会改变已冻结的 referenceDate；
- Capture 层没有 SwiftData 依赖。

### 阶段 D：接入受约束的远程结构化 Provider

目标：提升复杂口语、多物品和上下文解析能力，同时保持 Butler 安全边界。

已确认决策：

- 首发优先 OpenAI；
- 用户提供凭据；
- 支持文字、相关库存候选、语音、图片、小票和订单上传；
- 大模型联网使用，不要求离线模型；
- 数据不得用于训练；
- 优先验证并复用 OpenMinis ChatGPT/Codex OAuth，OpenAI API Key 作为稳定并存路径。

建议新增：

- `Butler/Services/Planning/RemoteInventoryPlanProvider.swift`
- `Butler/Services/Planning/InventoryModelClient.swift`
- `Butler/Services/Planning/InventoryPlanningConfiguration.swift`
- `Butler/Services/Planning/InventoryPlanSchemaValidator.swift`
- `Butler/Services/Planning/ProviderAdapter.swift`
- `Butler/Services/Security/ProviderCredentialStore.swift`
- `Butler/Services/Security/OpenAICodexOAuthAdapter.swift`
- `Butler/Services/Privacy/PlanningPrivacyPolicy.swift`

建议修改：

- `SettingsView.swift`
- `InventoryPlanProvider.swift`
- `InventoryInputCoordinator.swift`
- `Info.plist` 或生成 Info 设置

执行步骤：

1. 先用 Mock Provider 完成成功、超时、取消、非法 JSON 和高风险字段测试。
2. 实现统一 Keychain credential store，覆盖 API Key、access token、refresh token、退出和撤销。
3. 从 OpenMinis 直接提取 `CodexOAuthManager.swift` 及对应 OpenAI/Codex Provider 代码，保留 PKCE、token refresh、错误处理和请求协议，通过 Adapter 接入 Butler。
4. 用真实 Plus/Pro 和无资格账户验证登录、权限、模型、限额、structured output、图像输入、后台恢复和退出；记录哪些能力实际可用。
5. 并行接入用户 API Key 路径，作为正式稳定后备，不等待 OAuth 结论才继续开发。
6. 定义 structured output schema，操作类型必须对应现有白名单。
7. Response 先经过 schema validator，再 Codable decode，再 Policy。
8. 对非法版本、未知 operation、非法 confidence 和缺失 evidence 直接拒绝。
9. 高风险字段不做 fuzzy repair。
10. 设置页展示登录/API Key 状态、供应商、上传数据类别、训练数据说明、Data Controls 提示和清除凭据。
11. 保留 Local Provider 处理本地可完成任务，但不能把远程模型已经生成的半个计划继续执行。
12. OAuth 路径在真实账户验证完成前保持 feature flag；API Key 路径在对应门禁通过后可独立发布。

验收语句至少覆盖：

```text
昨天在超市买了半斤牛肉，两盒下周过期的特仑苏
冰箱里还有两瓶牛奶，我刚喝完一瓶
三包方便面先放常温，冰激凌放冰箱
这盒药生产日期是五月，保质期二十四个月
```

每条验收必须检查：

- 多物品数量和单位；
- 真实日期与估算日期分离；
- 模糊字段进入追问；
- 同名已有产品不自动合并；
- 药品严格确认；
- 用户未点击确认前数据库没有变化。

### 阶段 E：领域查询工具和任务型助手

目标：让用户可以自然语言查询库存和提出动作，但模型仍不能直接执行。

为什么：

这是 OpenMinis Tool Calling 最值得借鉴的部分，也是最容易越权的部分。必须先有 V2 读取路径、稳定 Policy 和 Repository。

建议新增：

- `Butler/Domain/InventoryToolDefinition.swift`
- `Butler/Domain/InventoryQuery.swift`
- `Butler/Services/InventoryQueryService.swift`
- `Butler/Services/InventoryToolDispatcher.swift`
- `Butler/Services/InventoryAssistantCoordinator.swift`
- `Butler/Views/Assistant/AssistantInputSheet.swift`
- `Butler/Views/Assistant/InventoryResultCard.swift`
- `Butler/Views/Assistant/InventoryActionReviewCard.swift`

执行步骤：

1. 集中声明工具名、描述、参数和风险等级。
2. 只读查询通过 `InventoryQueryService` 返回 DTO。
3. 查询必须使用结构化 filter，不接受模型生成 Predicate。
4. 写意图转换为现有 `InventoryOperationPlan`。
5. Tool Dispatcher 不持有 ModelContext。
6. 工具执行前运行参数 preflight。
7. 所有写工具命名为 propose，不命名为 execute。
8. 同一 Agent turn 中只读查询未来可以并发，写意图首期顺序处理。
9. Assistant UI 只展示 Butler 需要的输入、结果、追问和审核卡；可直接复用 OpenMinis 的输入框、附件、语音波形、消息渲染和流式状态组件，但不必带入无关的 Shell、Browser、Skill 和 Session 管理。
10. 对话历史不是库存事实来源。重新打开 App 后查询必须重新读取结构化数据。

核心验收：

```text
“冰箱里有什么三天内要过期？”
  -> 只读查询，不写数据库

“我刚喝完一盒牛奶”
  -> 若唯一批次明确，生成数量调整计划
  -> 若有多个批次，要求选择
  -> 用户确认后执行

“把所有牛奶都删掉”
  -> 不存在原始删除工具
  -> 返回可解释拒绝或逐批次关闭建议
```

### 阶段 F：M3 风险分诊和系统 Action Outbox

目标：把临期提醒连接到可执行行动。

建议新增：

- `Butler/Models/V2/PendingSystemAction.swift`
- `Butler/Services/SystemActions/SystemActionWorker.swift`
- `Butler/Services/SystemActions/NotificationActionExecutor.swift`
- `Butler/Services/SystemActions/ReminderActionExecutor.swift`
- `Butler/Services/SystemActions/SystemActionAuthorizationCoordinator.swift`
- `Butler/Views/Actions/ActionCenterView.swift`

建议修改：

- `ButlerStore.swift`
- `InventoryRepository.swift`
- `NotificationManager.swift`
- `ButlerApp.swift`
- `SettingsView.swift`

执行步骤：

1. 先为新增 Schema 运行兼容测试。
2. Repository 同事务写入 PendingSystemAction。
3. save 成功后由 worker 执行。
4. worker 使用稳定 action ID 保证幂等。
5. 区分授权拒绝、临时失败、永久失败和成功。
6. 后台重试采用有限次数和退避，不无限循环。
7. 通知动作使用 lot ID 和 expectedRevision。
8. Action Center 展示待处理、失败和已处理。
9. 把启动即请求通知权限改成上下文式授权。

验收：

- 库存事务失败时不发送通知；
- 系统动作失败时库存事实仍然正确，Action 保留可重试；
- 重复执行 action ID 不产生重复提醒；
- stale notification action 不覆盖新批次状态；
- 权限拒绝不影响库存使用。

### 阶段 G：M4 个人模板和纠正学习

目标：让用户纠正逐步减少下一次输入成本。

建议新增：

- `Butler/Services/Learning/TemplateSuggestionService.swift`
- `Butler/Models/V2/TemplateSuggestion.swift`，作为 SwiftData 持久化模型
- `Butler/Views/Learning/TemplateSuggestionCard.swift`

执行步骤：

1. 只从 userEdited 和 userConfirmed 证据生成建议。
2. 建议与正式模板分离。
3. 用户确认后生成 `updateTemplate` operation。
4. 通过 Policy 和 Repository 更新。
5. 追加 templateUpdated event。
6. 提供关闭个性化建议和删除个人模板的入口。

验收：

- 模型推断不能直接更新模板；
- 拒绝建议后不重复轰炸用户；
- 模板变化可审计；
- 模板不会修改过去批次的包装事实。

### 阶段 H：M5 Share Extension、图片、小票和订单候选

目标：降低高信息量物品的录入成本。

建议新增：

- `ButlerShareExtension` Target
- `Butler/Shared/PendingCaptureTransfer.swift`
- `Butler/Shared/ButlerAppGroup.swift`
- `Butler/Services/Vision/VisionOCRService.swift`
- `Butler/Services/Vision/BarcodeService.swift`
- `Butler/Services/Vision/VisionInventoryPlanProvider.swift`
- `Butler/Views/Capture/CaptureInboxView.swift`
- `Butler/Views/Capture/CaptureEvidenceView.swift`

建议修改：

- `Butler.xcodeproj/project.pbxproj`
- App 与 Extension entitlements
- URL scheme / App Intents 配置
- `ButlerStore.swift`
- `ContentView.swift`
- `Info.plist`

执行顺序：

1. 先确认 App Group ID、签名和现有数据库位置。
2. 只建立 transfer 目录，不移动 SwiftData 数据库。
3. 实现纯文本分享。
4. 验证冷启动、热启动、重复分享和失败恢复。
5. 再加入图片；PDF 通过预设 OCR/解析质量基准后正式开启，否则保留查看和手动处理路径。
6. 本地 OCR 和条码先行，再按 9.5 的 Provider 协议接入外部目录。
7. 远程视觉 Provider 受单独隐私开关控制。
8. 所有外部数据进入 Capture Inbox，不直接写库存。
9. 用户审核后才创建正式 Product/Lot。
10. 增加订单网页、订单截图和邮件正文/附件导入，统一保留来源。
11. 未处理和失败 Capture 无限期保留并提醒。
12. 只有完成转移、确认无引用后才清理 App Group 传输副本。
13. 增加本地证据长期保留，并为 CloudKit 私有 `CKAsset` 同步预留 metadata 和状态。

验收：

- 连续分享两张图片不会覆盖；
- 同一系统回调重复交付不会重复导入；
- Extension 被中途终止不会留下可消费的半条记录；
- App Group 路径不能逃逸；
- 超大文件和未知格式被拒绝；
- OCR 失败时原始分享仍留在 Inbox；
- 未授权时图片不上传；
- 包装日期始终进入确认。

### 阶段 I：建立 Butler Core

目标：把已经在 Inventory 中验证的规划、权限、确认、事件和行动机制提升为可承载多个生活领域的管家内核。

建议优先复用 OpenMinis：

- Agent Loop 和 Tool Definition；
- Provider Router；
- Session、Context 和 Memory；
- Skill Store；
- MCP Store；
- Offload Permission；
- Background Task；
- Tool Result 和消息渲染；
- Deep Link、Quick Action 和 Share Pipeline；
- Shell、Browser 和 Workspace 的沙箱能力。

执行步骤：

1. 建立 `ButlerCapability`、`ButlerToolRequest`、`ButlerToolResult` 和 `ButlerPermission`。
2. 建立 Capability Registry，Inventory 作为第一个注册模块。
3. 建立 Permission Broker，支持单次、会话、长期和高风险再次确认。
4. 建立多层 Memory，区分事实、偏好、习惯、对话和程序性记忆。
5. 复用 OpenMinis Agent Runtime 时，通过 Adapter 保留 Butler 的 InventoryPolicy 和 Repository。
6. Skills 和 MCP 当前不进入近期版本；Capability Registry 保留适配点，未来出现真实场景时优先复用 OpenMinis 管理能力。
7. Shell、Browser 和 Workspace 当前不进入近期版本；未来需要时作为高权限 Capability 直接评估和复用 OpenMinis 实现，而不是永久禁止。
8. 建立统一管家界面，能够显示不同 Domain 的结果卡和行动卡。
9. 建立跨 Capability 审计记录，用户可以查看 Butler 做过什么。
10. 支持取消、后台任务、失败恢复和长期自动化。

验收：

- Inventory 行为和安全不变量不回退；
- 新 Capability 不需要修改 Agent 核心；
- Permission Broker 可以撤销任一 Capability；
- Memory 类型之间不会互相冒充事实；
- Tool 执行具有稳定 correlation ID；
- 用户可以查看和停止后台工作；
- Shell、Browser 等高权限能力只能在授权范围内运行。

### 阶段 J：扩展生活领域

Butler Core 建立后，根据用户价值逐个增加 Domain，不需要预设永久上限。

已确认的近期 Domain 顺序：

```text
Inventory
  -> Household Tasks
  -> Shopping
  -> Calendar
  -> Health
```

后续候选，不设永久上限：

```text
Reminders
  -> Receipts / Documents
  -> Medication
  -> HomeKit
  -> Browser Research / Transactions
  -> Files / Automation
  -> Skills / MCP Ecosystem
```

每个新 Domain 应：

1. 先定义用户任务和成功指标；
2. 检查 OpenMinis 是否已有可复用 Tool、Offload、UI 或 Store；
3. 声明数据模型、权限等级和可撤销方式；
4. 接入 Capability Registry；
5. 提供结构化事实存储或明确外部事实来源；
6. 定义主动服务触发条件；
7. 经过对应 Domain 的风险和回归测试；
8. 再决定是否支持长期自动化。

长期目标允许 Butler 在用户授权下主动工作，而不只等待每次手动输入。

## 14. 测试矩阵

### 14.1 Unit Tests

- CaptureEnvelope 编解码、referenceDate 冻结；
- PendingCapture 状态机和重复交付；
- 路径和 UTType 校验；
- Plan schema version 和 operation whitelist；
- evidence 完整性；
- 日期类型分离；
- confirmation receipt 精确匹配；
- query filter 校验；
- provider timeout、cancel 和 retry；
- Keychain 错误；
- SystemAction 幂等和退避；
- TemplateSuggestion 来源限制。
- Capability 注册、禁用和重复 identifier；
- Permission Broker 的单次、会话、长期、撤销和高风险升级；
- 事实、偏好、习惯、对话和程序性 Memory 的隔离；
- Skill / MCP 工具声明不能绕过 Capability 权限；
- Shell / Browser 请求的授权范围和取消。

### 14.2 Integration Tests

- 文字 -> plan -> review -> repository；
- 语音 transcript -> 相同 plan 管线；
- Share Extension -> App Group -> Capture Inbox；
- 图片 -> OCR -> candidate -> review；
- 远程 Provider 非法 JSON -> 无写入；
- Provider 成功但 Policy 拒绝 -> 无写入；
- 用户确认后 revision 变化 -> 旧 receipt 失效；
- 库存 save 成功、通知失败 -> outbox 保留；
- 冷启动 deep link -> 正确页面；
- 热启动时已有 sheet -> 状态机仍能呈现目标入口。
- 一个 Agent 任务跨 Inventory 和 Calendar Capability 的权限协调；
- 长期授权撤销后，后台任务不能继续调用对应 Capability；
- 对话 Memory 提供上下文，但查询结果仍来自结构化事实；
- Skill 或 MCP 动态增加工具后，Capability Registry 和审计记录保持完整；
- Shell / Browser 后台任务取消后不会继续产生副作用。

### 14.3 UI Tests

- Clarification Card 可访问性；
- 多产品审核；
- 同名产品选择；
- 三类日期标签不混淆；
- 权限拒绝后的恢复路径；
- Share Inbox 失败重试；
- 通知快捷操作 stale revision；
- Capability 权限中心的查看、授权和撤销；
- 长期 Memory 的查看、编辑和删除；
- 跨 Domain 结果卡和行动卡；
- 后台任务的查看和停止；
- Dynamic Type、VoiceOver 和深色/浅色模式；
- 最低支持系统。

### 14.4 隐私和安全测试

- Release 日志不出现 API Key；
- Release 日志不出现完整输入和 OCR；
- 无授权不发网络请求；
- 关闭云模型后立即停止后续上传；
- 删除凭据后无法继续请求；
- App Group 相对路径不能访问根目录外；
- 文件 hash 不一致时拒绝消费；
- 恶意文件名不影响最终路径；
- 重复通知回调不重复扣减库存。
- 已撤销 Capability 不能被 Agent、Skill、MCP 或后台任务继续调用；
- Memory 中的自由文本不能被当作结构化事实直接写入；
- Shell 和 Browser 只能访问授权的 Workspace、站点和时间范围；
- 跨 Capability 调用保留完整 correlation ID 和审计链；
- 长期自动化超出金额、对象、频率或时间范围时必须停止。

## 15. Feature Flags 和回滚

建议集中管理：

```text
v2DashboardEnabled
v2ProductionInputEnabled
remotePlanningEnabled
inventoryAssistantEnabled
systemActionOutboxEnabled
shareCaptureEnabled
remoteVisionEnabled
templateSuggestionsEnabled
butlerCoreEnabled
longTermMemoryEnabled
skillsEnabled
mcpEnabled
shellCapabilityEnabled
browserCapabilityEnabled
calendarCapabilityEnabled
healthCapabilityEnabled
homeCapabilityEnabled
```

规则：

- 默认值全部 false，已有稳定功能除外；
- Debug 可以通过启动参数覆盖；
- Release 不允许隐藏启动参数绕过用户授权；
- 关闭功能后不得删除数据；
- Schema 一旦发布，只能 additive 演进；
- 回滚 App 版本时必须考虑新 Schema 的可读性；
- feature flag 不能绕过 Policy 或 confirmation。
- feature flag 表示阶段性发布状态，不代表 Capability 永久禁止。

## 16. 后续 AI 的执行协议

后续 AI 每次只接手一个阶段或一个明确工作包。

开始前必须按顺序阅读：

1. `docs/BUTLER_2_SPEC.md`
2. 本文
3. `DEVELOPMENT_LOG.md`
4. 当前工作包涉及的完整源文件和测试

开始编码前必须输出：

```text
当前工作包
涉及文件
保持不变的不变量
需要新增的测试
是否改变 Schema
是否改变 App Group / entitlements
是否发送网络数据
计划直接复用哪些 OpenMinis 文件、类型或组件
属于哪个 Butler Capability
需要哪一级权限和哪种授权持续时间
使用哪类 Memory
```

实施规则：

1. 一次只完成一个工作包。
2. 不顺手重构无关代码。
3. 不删除旧 Item 或旧读取路径，除非规范已经更新。
4. 不使用 `try?` 吞掉持久化错误。
5. 不自动创建同名产品合并。
6. 不把 estimated date 写入 package expiry。
7. 不让测试直接使用用户数据库。
8. 不在日志中记录敏感数据。
9. OpenMinis 已有成熟实现时优先复用；记录来源、适配点和未带入的依赖，避免重复造轮子。
10. 如果发现本文与实际代码不一致，先记录差异，再调整计划。
11. 不得把第一阶段的非目标解释为 Butler 永久不能拥有的能力。
12. 新增权限时优先补齐 Permission Broker、撤销和审计，不以“减少权限”代替正确设计。

每个工作包完成后必须报告：

```text
修改文件
行为变化
测试命令和结果
未执行的验证
新发现的风险
是否更新 DEVELOPMENT_LOG
是否满足阶段验收
是否仍保持 feature flag 关闭
```

必须停止并请求产品所有者决定的情况：

- 需要上传文字、库存候选、语音、图片、小票和订单之外的新数据类别，或改变已经展示给用户的上传用途；
- 需要修改包装日期语义；
- 需要自动合并产品；
- 需要引入删除或永久抹除；
- 需要改变数量单位模型；
- 需要移动数据库到 App Group；
- 需要启用家庭共享；
- 需要在 Release 打开尚未通过门禁的功能。

## 17. 已确认产品决策和仍需按结果判断的事项

本节是后续 AI 的决策基线。不得把“当前不做”改写成“永久禁止”，也不得重新提出已经确认的问题，除非新的代码事实或外部平台变化使原决策无法执行。

### 17.1 已确认决策

| 编号 | 决策 | 执行含义 |
|---|---|---|
| 1 | 最低系统版本按能力需要选择 | 不固定 iOS 17 或 iOS 26；采用某 API 时选择能满足它的最低合理版本并记录原因 |
| 2 | App Group ID 为 `group.com.butler` | App、Share Extension、Widget 使用同一正式 ID |
| 3 | 规划 Widget | 建立独立 Target，并在数据库迁移之外单独接线和验证 |
| 4 | 不做长期 OpenMinis 上游追踪 | 每个工作包仍先检查可直接复用代码并记录来源，但不建立持续同步机制 |
| 5 | Domain 顺序为家庭任务、购物、日历、健康 | Inventory Core 稳定后按此顺序推进 |
| 6 | 自主程度由用户选择 | Permission Broker 提供建议、单次确认、会话授权、长期授权和规则自动执行 |
| 7 | Dashboard 与对话并存，每页可快速对话 | 建立全局 Conversation Launcher 和页面上下文快照 |
| 8 | 长期记忆默认开启 | 必须可查看、编辑、删除、暂停和分类关闭 |
| 9 | 当前不需要第三方 Skills/MCP | 保留扩展点，出现真实需求时优先复用 OpenMinis |
| 10 | 当前不需要 Shell/Browser | 不进入近期版本，未来按 Capability 和权限启用 |
| 11 | 首发优先 OpenAI | 优先验证 OpenMinis ChatGPT/Codex OAuth，API Key 稳定并存 |
| 12 | 凭据由用户提供 | Keychain 保存，Butler 首期不代理统一模型账号 |
| 13 | 支持上传全部当前规划数据类别 | 包括文字、相关库存候选、语音、图片、小票和订单，实际请求发送任务所需子集 |
| 14 | 数据不得用于训练 | API 路径使用不训练默认/配置；ChatGPT 登录路径提示并检查 Data Controls |
| 15 | 大模型必须联网 | 离线保留查看、本地语音、手动操作和本地规则能力 |
| 16 | 默认保存脱敏诊断元数据 | 不保存原始响应；显式 Debug 模式可本机加密短期保存 |
| 17 | 复杂输入可并行处理并统一进入审核 | 优先流畅体验，不增加无意义的摘要等待页 |
| 18 | 多个低风险物品可视情况批量确认 | 高风险、歧义或不同动作组拆分确认 |
| 19 | 唯一合理批次允许一步确认 | revision、对象和数量必须明确，并提供撤销 |
| 20 | 通知动作按风险决定确认 | 查看/稍后无需确认；唯一低风险用尽可直接执行；丢弃、药品、歧义进入审核 |
| 21 | 使用 Butler 内部购物清单 | Apple Reminders 可作为未来可选同步/导出 Capability，不作为事实主库 |
| 22 | 模糊日期只保留候选 | 不写成伪造的精确日期 |
| 24 | 图片等证据默认长期保留 | 本地可用，优先增加 iCloud 私有同步；用户可管理和删除 |
| 25 | `TemplateSuggestion` 持久化 | 使用 SwiftData 支持生命周期、去重、同步和审计 |
| 26 | System Action Outbox 进入 SwiftData | 与业务事实和 Event 同事务保存 |
| 28 | 支持电商订单网页、邮件和图片识别 | 全部进入 Capture Inbox 和人工审核 |
| 31 | 未处理 Capture 无限期保留并提醒 | 只有用户完成或明确丢弃后才结束，不按固定天数删除 |

### 17.2 条件支持和延后决策

| 编号 | 当前结论 | 触发下一步的条件 |
|---|---|---|
| 23 | 分数数量、克/毫升和单位换算延后 | 出现足够真实用例后单独设计 Quantity 模型和迁移，当前不提前锁定 |
| 27 | PDF 小票条件支持 | OCR、表格恢复、页数和错误率达到验收基准则开启；否则保存原件并允许手动处理 |
| 29 | 条码外部目录条件支持 | 找到覆盖率、稳定性、授权和成本可接受的 Provider 即启用 |
| 30 | 采用 Provider 抽象和本地私有缓存 | 具体 Provider 确定后调整 TTL、授权和字段映射；用户事实永远优先 |

### 17.3 后续仍需要通过实验回答的问题

1. OpenMinis 的 ChatGPT/Codex OAuth 在 Butler 的真实 Plus/Pro 账户、iOS 生命周期、限额和模型能力下是否稳定，是否能作为正式首选而不仅是实验路径。
2. 哪个 PDF 样本集和成功率足以定义“效果可用”；建议至少覆盖超市小票、电子发票、多页订单和扫描件。
3. 哪个条码目录在主要市场和语言下覆盖足够，并允许 Butler 的预期使用方式。
4. iCloud 证据同步采用 CloudKit `CKAsset` 还是 iCloud 文件容器；在开始实现前用大文件、冲突和离线恢复样本选择更可靠方案。
5. 健康 Domain 的首批具体场景是什么。健康权限和数据语义差异很大，应在进入该阶段时再定义，而不是现在限制未来能力。

## 18. 推荐的第一批实际工作

基于以上已确认决策，推荐按以下工作包开始：

```text
工作包 1:
  建立 ButlerTests
  完成 M0/M1/M2 Apple 平台验证

工作包 2:
  建立 V2 只读 Repository 和 Debug V2 Dashboard

工作包 3:
  定义 CaptureEnvelope
  让现有文字和语音走统一 Capture 管线

工作包 4:
  用 Mock Remote Provider 完成协议、隐私和错误测试
  直接复用 OpenMinis ChatGPT/Codex OAuth 做 feature-flagged 实验
  并行接入用户 OpenAI API Key 稳定路径

工作包 5:
  建立每页可用的 ButlerConversationLauncher
  直接复用 OpenMinis 输入、附件、语音和流式消息组件

工作包 6:
  建立持久 Capture Inbox
  未处理和失败内容无限期保留并提醒
  接入图片、订单和邮件候选，PDF 与条码按质量门禁启用
```

工作包 1 至 3 先建立可靠事实基线。工作包 4 开始真实联网能力，但必须遵守用户选择、Keychain、数据用途说明和“不用于训练”的约束。所有工作包实施前都应主动检查 OpenMinis 是否已有可直接复用的 Provider、状态机、预检、权限、Memory、Share 或 UI 组件，并优先复用成熟实现。

## 19. 最终判断

Butler 应该越来越有能力，也应该越来越理解用户。Inventory 是第一个成熟领域，用来验证事实、规划、确认、行动和学习闭环；验证成功后，这套方法应扩展到更多生活事务，而不是把 Butler 永久收窄到物品管理。

OpenMinis 的通用执行、Provider、Memory、Skills、MCP、权限、状态机、系统集成、Shell 和 Browser 都可以成为 Butler 的长期能力来源。合适时应直接复用成熟代码，并通过 Butler Core 统一管理。

Butler 的长期职责链是：

```text
模型和 Agent 负责理解、规划与协调
Capability 负责声明可做的事情
Permission Broker 负责用户授权
Domain Policy 负责领域风险
Repository 或外部系统负责事实
Memory 负责偏好、上下文和程序性知识
Event / Audit 负责历史和可解释性
Adapter 负责复用并连接 OpenMinis 与 Apple 系统能力
```

能力扩展和执行控制不是对立关系。清晰的 Capability、Permission、Memory 和 Audit 正是为了让用户能够放心地授予 Butler 更多权限，让它从物品管理逐步成长为真正的个人管家。
