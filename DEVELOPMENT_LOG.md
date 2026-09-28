# Butler Project Development Log & Handover Notes

## 页面上下文对话、设置工具、分阶段任务与输入框
**Date:** 2026-09-28 · 基于 `8f1c3b9` 的本地开发 · Xcode 26.3 / iOS 26.2 Simulator

- 新增 `ChatScope` / `ChatSessions`：首页通用、库存列表、物品批次、任务、设置和日期各自保存对话、摘要、草稿、照片及待确认状态；账号、Jev、笔记和实体资料共享。旧历史保留通用归属，不再截断到最近 2000 轮；损坏文件阻止覆盖。每轮通过工具数据读最新上下文，不把对象文字当系统指令。
- 通用会话查询/修改的对象与新建批次真实 ID 会建立关联。物品/任务详情和历史工具可回看相关原文及来源，不复制消息；日记汇总所有会话。备份升级 v2，包含各会话附件、草稿及全部 9 项允许的配置，并兼容旧备份和恢复后缓存刷新。
- 新增设置读取/提议工具，校验合法值和确认时旧值；新增任务读取、结构化分阶段计划与生命周期动作。修改保持 ID、递增版本，拒绝过期提议；规则预览、完整规则摘要、实际回执和调度警告一起可见。任务完成/暂停/取消撤销计划及关联稍后提醒，通知完成按钮现可执行；活动历史保留。
- 支持一次、每日、每周、有限分钟间隔、阶段起止/次数、全局截止、明确约定自动完成。单个合适的周期规则用系统重复，其余本地预排；任务通知预算 40 条，超出会说明覆盖与补排限制。通知预先按自动完成时间截断，前台计时或回前台时同步完成状态。没有增加云调度、外部状态触发或每次重复单独完成。
- 输入区左加号、右外置麦克风/发送；已有文字/附件时框内保留无背景线性麦克风。加入录音准备、收尾、关闭/切页/中断的会话归属保护；录音期间锁手动编辑，停止后保留文字再发送。长按水晶球保留原松开发送。会话标题移至导航栏中央，避免被 Liquid Glass 工具栏挤掉。
- 初轮测试发现 SubscriptionModel / MotionTilt 释放经过隔离析构路径时崩溃；两类无执行器绑定清理，显式使用 nonisolated deinit 后相关测试通过。并行复测另遇模拟器 worker 被终止，改为串行。旧 Jev 分享测试随后暴露提前销毁宿主窗口的生命周期竞态，改等真实展示/关闭/释放条件，保留对象释放和临时文件删除断言；未修改生产分享业务。
- 最终完整串行 `xcodebuild test`：**237 项，236 通过 / 1 项原有 Item-only 迁移跳过 / 0 失败**。本轮新增 57 项测试，覆盖会话隔离/旧数据/损坏/备份、设置白名单与并发校验、任务阶段/次数/DST/状态/版本、跨会话关联、输入与录音状态。测试结果：`/private/tmp/butler-context-build/Logs/Test/Test-Butler-2026.09.28_16-27-10-+0800.xcresult`，文本 `/private/tmp/butler-context-verified-tests.log`。
- 签名 iPhone Release 构建通过，日志 `/private/tmp/butler-context-release.log`；存在原有的 actor isolation 编译警告，未扩大本轮修改去重构无关代码。最后仅对设置页加共享请求期间退出/移除密钥/对照测试的禁用保护及取消文案，已由该 Release 构建覆盖。
- 原生模拟器检查：空白外置麦克风、有字外置发送+内侧线性麦克风、通用草稿重启保留、任务/设置会话独立标题与空草稿、任务暂停状态与首页安排联动。任务多阶段与通知取消主要由规则/状态测试验证；未做真实模型中文端到端评估、真人录音或真机通知送达验收。
- 用法与能力边界保存在 [上下文管家与任务](docs/CONTEXTUAL_AGENT_DESIGN.md)。本轮未提交推送、未安装手机、未更新 TestFlight。

## 功能与 Jev 原理说明归档
**Date:** 2026-09-28 · 文档更新 · 源码基线 `93fe6da`

- 新增根目录 [README](README.md) 作为阅读入口，新增 [功能与工作原理](docs/FEATURES_AND_JEV_GUIDE.md)，记录当前功能、主模型/手机/Jev 分工、调用时机、购买四项物品的处理流程和预取开关对照方法。
- 明确区分已实现与讨论建议：新增请求仍可能先经预取判断；新增后合计展示、按需绕过前置判断、包装换算尚未形成完整实现。不能把建议写成已上线。
- 标注历史规格与宿主实验的时效范围，不覆盖原历史记录。此轮只修改文档，不变更应用逻辑，也不上传新测试版。

## 手机内文字管家与订阅直连
**Date:** 2026-09-26 · GPT-6 Sol / medium · Debug 虚构资料入口

- 原 HTTP 测试页已替换为 `OnDeviceChat`：原生文字输入、停止、修改前后预览、确认/取消、本机记忆浏览和搜索。无需地址、服务密钥、Mac 常驻程序或自购云服务器。原库存不变，新记忆位于 Application Support/agent-test-memory.json；草稿保存在本机，聊天暂不跨重启保留。
- `SubscriptionConnection` 实现设备码授权、系统钥匙串、刷新及退出；`SubscriptionModel` 直接 HTTPS 调用订阅模型，固定 gpt-6-sol / medium，不回退为其他模型或 API 付费。账号密码只在官方页面输入；必要的对话与查询结果发送给云模型。设备码实际授权仍需所有者在手机上完成，本次不传递现有凭证到 Mac。
- Orb 使用既有授权执行直接 HTTP 虚构测试，没有启动 Codex 进程或 Agent 服务。按 Swift 源码相同的工具定义和指令，观察到三轮 HTTP 200：search_memory 查询盒马麻薯 → set_remaining 指向盒马 ID、quantity=2 → 回复“请在手机界面核对后确认；目前尚未保存”。工具返回由测试脚本提供，不是手机持久化验证；Jev 请求为零。
- 首次直连测试揭示真实 SSE 在完整 output_item.done 后以 completed.output=[] 结束，原解析会丢失工具调用。已保留先前完整条目，并将现有回归用例改为真实空数组情形；未放宽不完整响应拒绝规则。Mac 首次构建发现 catch 的 error 遮蔽属性，已改为 self.error。
- 首轮全量 XCTest 为72通过/1跳过/3崩溃，不以重启测试进程后的局部成功冒充全量成功。三次崩在 LocalMemoryStore 释放，栈含 TaskLocal::StopLookupScope / swift_task_deinitOnExecutorImpl，与 [Swift #88036](https://github.com/swiftlang/swift/issues/88036) 的 iOS26.2 默认 MainActor 释放缺陷一致。该类无 actor 绑定的清理，增加明确 nonisolated deinit；保持原同步测试不变，避免改为 async 绕过触发场景。
- 最终签名 Debug/Release `xcodebuild build` 均通过；全量 `xcodebuild test` **76项，75通过/1原有旧Item-only迁移跳过/0失败**。5项订阅连接测试含替身网络、真实模拟器钥匙串、凭证刷新与 SSE 字节解析；不是实际账号登录。原3项同步释放测试均通过，未改成 async。
- 原生 UI 浅色2项通过：未登录禁止发送/账号说明、确认前为空、保存6、取消校正仍6、确认2、重开仍2。停止/离线最终2项通过：准确草稿保留、无修改保存、仍可读记录2。快速替身的停止竞速失败及测试脚本未清干净草稿的失败保留；仅DEBUG新增 --local-agent-slow（每步5秒）后验证停止，正常模型未加延迟。未启动HTTP服务，全部UI明确标注为本机替身。
- 源线程检查了欢迎、浅/深预览、重开记录、停止及离线图，按钮白字蓝底、状态可读。深色图是已有2再次提出2的预览，仅验证外观；6→2由浅色流程验证。键盘弹起会缩短欢迎文字的滚动视口，无键盘时完整。精确命令/计数：`.amp/in/artifacts/ondevice-final-results.txt`；原始汇总：`ondevice-final-unit-summary.json`；截图：`ondevice-final-*.png`。完整日志与xcresult保留在Mac artifacts验证目录。
- 仅文字与轻量记忆；Jev、照片、语音、日期专用校验、提醒、正式库存整合、语义检索、记忆删除/撤销均未接入。当前不是正式发布版，未提交、推送或安装到用户手机。

## 纠正路线：手机内轻量执行与本地记忆
**Date:** 2026-09-26 · Foundation / Swift 6 · 尚未接通 UI 和真实模型

- 所有者明确不需要完整编程 Agent、常驻 Mac 服务或额外云服务器。当前目标是 iPhone 保存资料与执行查询/修改，云模型负责理解判断；订阅登录与模型请求是独立连接层。规格 §0 已纠正，`agent-host/` 保留为历史实验，不继续作为产品前提扩展。
- 新增 `LocalAgent.swift`：自由文本记忆加可选数量，无强制类型或标签；`search_memory`、`propose_memory`、`set_remaining` 三个本地工具。模型接口只接收会话与实际查询结果，不直接持有存储。保存或取消由调用方执行并留下会话回执，模型不能调用确认工具；重复工具请求复用结果，失败清除未完成预览。
- `LocalMemoryStore.openOnDevice()` 指向 App 自己的 Application Support/agent-test-memory.json，与现有 SwiftData 库及历史宿主 SQLite 分开。单实例拥有文件，整体原子替换；确认回执随记录一起保存。取消不写盘、重复确认不重复写、损坏文件报错不覆盖。当前只是小规模虚构数据内核：文字包含查询，未做语义索引、正式迁移、删除/撤销、日期专用校验、后台任务或持久聊天；后续接入不能把这些写成已完成。
- Mac 独立临时 Swift package 仅编译原始内核及测试：`xcrun swift test` **6 passed / 0 skipped / 0 failed**。验证跨实例重读、绝对数量校正且另一商店不变、自由文本无分类、过期预览、原子写失败、损坏文件保留、模型查询工具回传与不可自行确认、工具去重、取消与模型失败清理。工具请求来自明确测试替身，不是中文理解评估。
- iOS26.2 simulator SDK 下 `swiftc -typecheck -swift-version 6` 通过，加 `-default-isolation MainActor` 也通过，无诊断。无完整 App 重编译、无界面改动、无真实网络或模型调用、无订阅凭证操作；不需要模拟器设备。命令与证据在 `.amp/in/artifacts/localagent-mac-commands-results.txt`、`localagent-mac-evidence.tar.gz`。
- 当前界面的旧 HTTP 测试客户端仍未替换；下一步把订阅直连适配与现有 SwiftUI 对话接到本地循环，不恢复外部宿主依赖。未提交、推送或发布，不能宣称已完成手机端真实模型闭环。

## SwiftUI Agent 测试入口与有限手机接口
**Date:** 2026-09-26 · GPT-6 Sol / Medium · 虚构数据原型

- 新增 Debug 专用对话页、连接设置、修改前后预览、确认/取消和已保存记忆。钥匙串保存服务访问密钥，发送未知状态保留消息编号用于原请求重试；旧库存入口和正式库不变。当前仅文字输入，不包括 Agent 语音、拍照或通知。
- 新增仅回环监听的宿主 HTTP 服务，认证后只允许读取状态、提交消息和确认/取消预览，不公开 Codex 管理接口。数据独立保存在 `.local/mobile-fictional.sqlite`；消息和确认回执持久化，重启清除未确认预览并标记中断请求，不自动重放模型调用。
- `npm test`：30 passed / 0 failed；`npm run check`：Codex 0.157.1 协议检查和订阅握手成功。真实 HTTP 两轮模型测试输出 `REAL MOBILE API PASSED`：新建虚构联调麻薯6个，重复确认不新增第二笔，再校正剩余2个；直接核对保存结果。Jev调用0次。
- Mac 最终独立快照签名 Debug/Release 均 `BUILD SUCCEEDED`；全量 XCTest 65项，64通过、1个原有 Item-only 迁移测试主动跳过、0失败，包含新增3项客户端测试。真实 HTTP/SQLite/SwiftUI 使用替身模型 session；浅色完整链、深色预览/取消、停服错误三条 UI 测试分别通过。不复制订阅凭证、不改用户 checkout；不宣称已完成真机到模型的联调。
- UI 实测发现预览不自动刷新，已改为 busy/connected 变化启动独立轮询任务；最终4次自动查询间隔约1.03–1.08秒，无手动刷新绕行。确认前数据库为空，确认6个、取消仍6个、再确认2个、重开仍2个；最终恰好1条记录、2次操作及2个确认回执。修正确认按钮继承深色文字的问题；浅/深预览、重开记录、错误密钥和离线截图均已检查。命令及证据包保存在 `.amp/in/artifacts/agent-final-verification-commands.txt` 和 `agent-final-evidence.tar.gz`。
- 无签名模拟器包首次连接因钥匙串权限失败（OSStatus -34018），ad-hoc 本地签名后正常保存密钥，错误密钥401/正确密钥200与界面提示通过。不修改生产源码，不绕过钥匙串；后续 UI 验证应使用带签名模拟器包。
- 真机试用仍需确定私有 HTTPS 宿主连接及签名安装。完整进程隔离未通过，禁止真实个人数据接入；未部署、提交、推送或发布。

## 习惯更正、歧义对话与权限边界检查
**Date:** 2026-09-26 · GPT-6 Sol / Medium · Linux orb

- 新增 `revise_note`：原笔记原位更新、保留历史和版本，不创建第二条冲突笔记，不修改已有批次。复用确认、事务和撤销机制；不提供任意路径或数据库指令。更正失败也使旧预览失效。
- `npm test`：26 passed / 0 failed；新增更正笔记不影响其他商店/批次、重开只读到最新笔记、旧版本拒绝、撤销恢复，以及模拟确认回复丢失后重开重复确认不重复写入。未声称真实网络断连已测。
- `node live-scenarios.mjs --live`：临时虚构库，两轮评估各5次真实对话，均通过多候选追问、山姆改口盒马（旧预览无法确认）、习惯改位置但保留每盒6个且不搬动旧批次、复购用新习惯且到期日留空。首轮发现模型复述确认ID出错，改为由宿主独立显示确认入口；第二轮增加不复述确认命令断言并通过，输出 `LIVE SCENARIOS PASSED`。测试驱动核对预览再确认，不让模型自我授权；Jev调用0次，临时数据库已清理，原有chat测试库不变。
- 权限检查：`unshare -Ur true` 成功；真实 `codex sandbox -P :read-only -C <临时工作目录> -- python3 ...` 返回0，虚构目录外 canary 的 `outside_read=True`、`outside_write=False`、`canary_unchanged=True`。仅验证此沙箱策略，不是完整app-server隔离；只读不能阻止目录外读取。未读取真实密钥，临时文件已清理。真实资料仍禁止接入，下一步需完整进程文件/网络隔离及实际工具权限验证。
- 未接入iOS、真实数据或公网服务；未提交、推送或发布。

## Agent 测试记忆持久化与确认写入
**Date:** 2026-09-26 · GPT-6 Sol / Medium · Linux orb

- 用户同意继续下一步。新增独立 SQLite 测试库 `agent-host/.local/fictional-memory.sqlite`，不是 iPhone 库；不连接 SwiftData、不迁移真实资料。Node 最低版本提高到22.13以使用内置 SQLite。
- 模型可查询记忆、查询历史、提出自由文本笔记/购买批次/绝对数量修改/撤销最近操作。持久保存只能由宿主 `/confirm <ID>` 完成；显示修改前后值并确认具体日期，新话语使旧预览失效。确认步骤仍为命令行，不是最终 iOS 交互。
- 笔记与本次批次分离，未知有效期留空；记录用户原话、前后值、版本。事务同时写记录/历史/确认回执；重复确认不重复执行，过期版本和变动后的撤销预览拒绝写入。一次一个操作；撤销自身留记录，再次撤销会恢复上次撤销。
- `npm test`：24 passed / 0 failed，包括独立子进程重读、6→2→6且另一商店不变、日期与数量拒绝、改口/取消/过期版本、并发历史变化、故障注入事务回滚、模型不能通过工具确认。
- 真实 CLI 测试：先验证提出预览不写库；再通过5轮 Sol/Medium 对话完成两家购买、盒马剩余数量校正、撤销、重启后查询。测试驱动先断言预览内容再发送宿主确认，不是模型自我批准。直接查询 SQLite 验证盒马6个/2026-10-02、山姆18个/2026-10-05及4条历史；输出 `LIVE PERSISTENCE CHECK PASSED`。本轮0次Jev请求。
- 仍待：操作系统级隔离、更多模型歧义/改口评估、真实取消断线、Mac验证、iOS接入。文字包含检索不是语义记忆；无笔记合并/修改、批次日期编辑、提醒、照片和多操作事务。人工确认仍是模型选错对象的关口。未使用真实个人数据，未提交、推送、部署或发布。

## Codex Agent 隔离接入原型（阶段 A，部分完成）
**Date:** 2026-09-26 · Node 26.10.0 / codex-cli 0.157.1 · Linux orb

- `agent-host/` 新增独立 Node 宿主：官方订阅设备码登录、stdio 双向通信、进程内多轮对话、取消与断线失败处理；版本和安装锁文件固定。
- 两项只读动态工具：三条虚构资料的文字检索，以及 Jev 1.13.0 条件判断适配器。Jev 默认关闭，显式启用后每进程最多 5 次，不自动重试/充值。没有库存写入、SwiftUI 改动或正式数据迁移。
- 查阅 Codex 官方源码并核对本地生成协议后，采用实验性动态工具而非额外 MCP 服务。独立 HOME/CODEX_HOME、不向 Codex 传 Jev key、无执行环境、shell 禁用、只读沙箱及权限请求拒绝；这不是完整 OS 隔离证明，接入真实资料前仍须验证全部工具可达性。
- `npm test`：16 passed / 0 failed，覆盖乱序/分片协议、超时不重放、同工具调用去重与冲突、Jev 输入输出校验/超时/计费开关、取消中工具返回及过期轮次事件。网络与模型结果为测试替身，不计作语义效果验证。
- `npm run check`：真实二进制协议字段检查成功。所有者随后完成官方设备码登录，返回 `App Server handshake: OK; authentication: chatgpt`。`git diff --check` 通过。
- 登录后以 `npm start -- chat` 执行两次会话共 5 轮真实模型请求：工具正确返回盒马每盒 6 个/冰箱上层和山姆每盒 18 个/冰箱下层；连续追问“那山姆的呢”正确；Jev 关闭时返回 `jev_spending_not_enabled`，主模型说明失败后自行判断；登机箱查询无结果时明确未知。全部是虚构资料，没有修改库存或发出真实 Jev 请求。
- 随后核对模型配置：代码沿用默认值；同配置新建会话回执为 `gpt-6-astra` / `reasoningEffort: null`，模型目录默认 `medium`。此前五轮未保存配置回执，不作逐轮证明。正式评估前需固定并记录配置。
- 所有者安全配置项目级 `TYPESAFE_API_KEY` 并同意测试；刷新 orb 环境后执行 `npm start -- chat --allow-jev`，新增一轮真实对话成功调用 Jev 一次：`source: jev_live`，562 输入 / 40 输出 tokens，263ms（Jev 请求耗时）。模型报告盒马/山姆相关性 0.62/0.17，回答冰箱上层。无重试、充值、真实生活资料或库存写入；这是链路验证，不是准确率评估。
- 所有者随后指定 GPT-6 Sol / Medium：会话和每轮请求已固定 `gpt-6-sol` / `medium`，禁止模型回退，校验并输出服务回执。新增不同模型、不同强度及缺失强度拒绝测试，`npm test` 17 passed / 0 failed。真实回执匹配，两轮对话成功：盒马查询调用 Jev 一次（228ms，562/40 tokens），追问山姆只查记忆；分别回答冰箱上层/下层。未使用真实生活资料。
- 待完成：更多 Jev 对照样例、Mac 环境、实际取消/断线与权限隔离。第一阶段尚未整体完成，未提交、推送或发布。

## Agent 管家新构想与实施路线
**Date:** 2026-09-26 · 仅文档更新，未接入服务

- 产品所有者确认：SwiftUI 原生入口，联网主模型负责对话与决策，Jev 作为内部条件判断子模型，统一个人记忆和定时任务；Agent 运行位置及正式存储方案尚未确定，不绑定 Pi。
- `docs/BUTLER_2_SPEC.md` §0 成为最新产品方向，取代旧消耗品限定和本地解析限定；保留库存数据安全约束与旧里程碑作为历史，不把旧测试结果当成新 Agent 验证。
- 写入对话首页、结果卡、轻量确认、记忆浏览和任务管理的交互规划，尚未制作视觉稿或修改 SwiftUI。
- 路线：连接与测试基线 → 可信对话操作 → 跨会话记忆 → Jev 条件判断接入与对照评估 → 照片/衣物/日程 → 主动任务与真机验证。Jev 资格申请与独立实验可以提前开展。
- 接入前需要模型账号/预算、Jev 访问资格与上传范围确认；真实存储变更前先验证备份恢复。没有上传个人数据、部署、提交、推送或发布。

## 基础纠错与可信库存维护
**Date:** 2026-09-26 · Xcode 26.3 (17C519) · iOS 26.2 Simulator (iPhone 17 Pro)

- 日期展示区分真实包装有效期、预计日期和个人计划；包装补日期必须主动选择并确认不是生产日期。OCR 拒绝生产日期、多个日期及歧义日期，扫描失败显示手动输入指引。
- 核对页逐条编辑名称、整数数量、单位、位置及日期；修改名称不改已有产品，不沿用原产品的推断保鲜天数。多同名产品逐个选择，无默认候选。语音切文字先保留转写。
- 详情支持部分消耗/数量校正、日期修改和清除；库存提供已处理记录。关闭/改数量后可撤销最新操作，保留历史、确认和恢复值证据；后续编辑会使旧撤销失效。旧关闭事件未保存原数量时不提供猜测性恢复。
- 新录入的临期物品补发一次提醒，重复同步不重复补发；首次授权后和回到前台重建提醒，通知点击路由到批次。Spotlight 使用有语义的绝对日期，避免剩余天数陈旧。搜索不把具体药名放大为所有药品，组合条件取交集。
- 在 Mac 的独立临时源码快照中验证，没有覆盖已有用户 checkout。Debug / Release 模拟器构建均 `BUILD SUCCEEDED`；全量 XCTest：**62 tests，61 passed，1 skipped，0 failures**。跳过的是现有的旧 Item-only 磁盘库升级测试，不代表该兼容性已通过。
- Orb 检查：`bash .agents/setup`、`git diff --check` 通过；47 个 Swift 文件的 tree-sitter 语法检查无错误。
- 独立 XCUITest runner 驱动原应用：录入审核编辑/多候选与日期/数量/历史两条完整流程通过；日期页浅色、深色分别通过默认禁用、核对启用、改日期后重新禁用和保存检查；最终详情检查通过。数量实测 5→3→撤销恢复 5。已检查实际截图，修正禁用按钮外观、滚轮占位和“今天”与日期重叠。首轮日期测试点击整行文字未打开开关，改为点击可见滑块后通过；不能把文字区域点击视为开关操作。
- 构建/测试命令为 `xcodebuild -project Butler.xcodeproj -scheme Butler -configuration Debug -destination 'platform=iOS Simulator,id=<专用设备 UUID>' CODE_SIGNING_ALLOWED=NO test`；Debug/Release 使用同一工程的 `build`。所有最终源码都在最后一轮构建和 62 项测试中验证。UI 测试通过既有 Debug 文本注入入口录入，不计作语音测试。
- 真机离线语音、相机 OCR、通知实际送达/点击仍需验证；模拟器不能替代这部分。未推送、未发布新的 TestFlight。旧章节仅保留历史，不代表当前工程仍缺少测试 Target 或使用旧 Item 界面。

## 听懂日常说法：本地中文解析器重写
**Date:** 2026-09-23 · Xcode 26.3 · iOS 26.2 Simulator (iPhone 17)

- Owner's phone has no Apple Intelligence, so the on-device Foundation Models route was dropped for now. `LocalInventoryPlanProvider` now uses `ChineseInventoryParser` + `ProductLexicon` (still fully on-device, no upload).
- Understands: missing amounts (defaults to 1, marked as estimate), vague amounts (点/些/几), 一打/半打, name-first amounts (牛奶两瓶), run-together lists without punctuation, 喝完了又买了两瓶, filler/hesitation words, 给宝宝…, weights (recorded as 1 份 with a note), storage before or after the item, 都放…, spoken package dates (明天过期 / 还有三天过期 / 10月5号过期), shelf life (保质期七天 → estimated), spoken plans (三天内喝掉 / 这周吃掉 / 尽快).
- Question policy: 冰箱 → 冷藏 inferred for fresh/produce; asked only for freezables (ice cream, meat, dumplings). Loose produce gets a typical-life plan suggestion instead of a photo request; packaged fresh food and medicine never get guessed dates.
- Re-purchases link to the single same-name product without asking; the review shows "家里已有同款 · 改" to undo. Multiple same-name products still ask. (Adjusts spec §8.5's "explicit choice" rule: the review screen is the confirmation.)
- Talking about finishing something ("牛奶喝完了") explains that this is done on the item page instead of misrecording.
- Speech recognition now requests punctuation. Review shows defaulted quantities with the dashed "我推断的" underline.
- Tests: 42 passed (sentence-level parser suite added). Extend `ProductLexicon` to teach new products.

## V2 直接接入与“青花”界面
**Date:** 2026-09-22 · Xcode 26.3 · iOS 26.2 Simulator (iPhone 17)

- Owner decision: legacy `Item` UI/`DataManager` removed; the app reads and writes V2 only (see spec §7 items 7–8). `Item` stays in the schema so existing stores open.
- New UI (Home / Capture / Clarify / Review / Detail / Inventory / Date capture) built from the Paper "butler" designs, light + dark. Design tokens live in `Butler/Design/Theme.swift`.
- Input pipeline (`InventoryInputCoordinator`, `LocalInventoryPlanProvider`) is now production code. Added "先跳过" (keeps the literal 冰箱, Home asks later) and a compartment answer that records a `systemEstimate` plan date, never a package date.
- Button commands go through `InventoryActions` (single-op plans, policy-issued receipts on explicit tap). Reminders and Spotlight are rebuilt from active lots on every change.
- Fixed: app target never used `Butler/Info.plist`, so mic/camera/speech usage strings were missing (crash on first mic use). Fixed a Swift 6.2 runtime crash when `@MainActor` classes deinit on the main thread (`nonisolated deinit`).
- Tests: 13 passed, 1 pre-existing skip. Simulator walkthrough of the spec §8.5 sentence verified end to end.
- Debug aids: `--seed-sample-inventory` launch argument; `BUTLER_CAPTURE_TEXT` env var opens Capture pre-filled.
- Fonts: Noto Serif SC Regular/SemiBold/Bold bundled (OFL, subset to GB2312 + app strings, ~8.5 MB total; rarer characters fall back to the system font). Re-run the subset if new UI copy uses characters outside GB2312. License notices in `Butler/Resources/Fonts`.
- Open: real-device voice not yet tested.

## Butler 2.0 M0–M2 source handoff
**Date:** 2026-07-26

- Repository state at handoff: M0 domain/schema and policy source is complete; M1 repository and explicit migrator source is complete; M2 input loop source is complete as a debug-only harness. None of these milestones is release-validated until the macOS/Xcode checklist below passes.
- Added the vendor-neutral planning boundary, deterministic bounded Chinese local planner, frozen-plan clarification revisions, exact catalog lookup, policy/review coordinator, and transactional V2 input flow.
- Debug builds can launch the isolated harness by adding `--m2-input-harness` to the scheme's launch arguments. The fixture “我今天买了一瓶牛奶、三包方便面和一个冰激凌。冰激凌先放冰箱了还没吃。” exercises conjunction splitting, later-clause detail association, and cold-storage clarification.
- The harness uses a temporary in-memory container and writes only `CatalogProduct` / `InventoryLot` through `InventoryRepository`; it cannot modify or leave invisible data in the normal app store. It does not write `Item`, merge products, or invoke legacy migration.
- The M2 coordinator, local planner, and V2 input UI are excluded from Release builds. M2 speech is on-device-only, while the unchanged legacy input retains its existing recognition fallback behavior.
- Production remains disabled: normal launches still show `ContentView` / the legacy Dashboard and input path. Enablement is blocked on M1 migration/build validation in macOS/Xcode and a Dashboard V2 read path.

- The normative product/domain/AI contract is now [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md).
- Added an additive V2 schema for products, inventory lots, field evidence, inventory events, recurring-product templates, and future legacy migration links.
- Added a versioned AI operation-plan contract and deterministic validation policy. Only the debug M2 coordinator connects validated plans to persistence; the Release app does not.
- Added an M1 transactional repository with exact replay conflict detection, revision checks, field evidence, trusted confirmations, and one event per operation.
- Added an explicit, idempotent legacy importer. It uses a fresh context, preserves the original Item snapshot, and conservatively treats all legacy dates as unverified estimates.
- Existing screens and `DataManager` still use the legacy `Item` model; there is no backfill or dual write.
- Before M0 can ship, compile and test old-store migration on macOS/Xcode. Do not delete or replace `Item` until V2 parity is proven.

### Mandatory macOS/Xcode handoff checklist

The current project has an application target only; it does not yet have a test target. Perform these tasks on macOS with Xcode 26.2 and the iOS 26.2 SDK, and record results here before enabling any V2 production path:

- [ ] Create a `ButlerTests` target and make M0–M2 domain/persistence code testable without changing Release behavior.
- [ ] Build the Butler scheme in both Debug and Release. Treat SwiftData macro, predicate, uniqueness, Observation, actor-isolation, and warning failures as blockers.
- [ ] Verify a clean installation can create and reopen the complete `ButlerStore.schema`.
- [ ] Generate a temporary database with the legacy `Item`-only schema, populate every compatibility fixture listed in `docs/BUTLER_2_SPEC.md`, then open that same file with the complete schema. Compare every legacy row and field before and after.
- [ ] Force a store-opening/migration failure and verify Butler neither deletes nor silently recreates the user's database.
- [ ] Test `InventoryRepository`: atomic rollback, exact idempotent replay, conflicting operation-ID rejection, stale revision rejection, missing entity handling, confirmation binding, evidence values, event creation, and integer overflow boundaries.
- [ ] Test `LegacyItemMigrator`: explicit invocation only, second-run idempotency, one link per old Item, conservative one-Product/one-Lot mapping, original snapshot preservation, and all legacy dates remaining unverified estimates.
- [ ] Launch Debug with `--m2-input-harness`. Confirm the default sentence creates exactly three review rows; only ice-cream storage is clarified; noodles receive a three-calendar-month `plannedUseByDate` and no `packageExpiryDate`; clarification preserves IDs; and no write occurs before final review confirmation.
- [ ] Verify exact-name product candidates never merge automatically, arbitrary candidate IDs are rejected, and confirmed existing-product selection rewires only the intended lot.
- [ ] Relaunch normally after using the harness and confirm the production store is unchanged. Confirm Release contains no M2 harness entry path.
- [ ] On simulator and a physical device, verify microphone/speech permissions, M2 on-device-only failure messaging, and the legacy local-first/server-fallback behavior. Do not approve cloud model upload as part of this test.
- [ ] Run legacy regression coverage for Dashboard, details, consume, discard, date completion, notifications, Spotlight, cold launch, and background/foreground transitions.
- [ ] Before production enablement, implement and verify a V2 Dashboard/read path. Only afterward may an explicit migration entry point or production M2 writer be considered; do not introduce dual-write.

Detailed fixtures, expected outcomes, and release gates are normative in [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md#8-macosxcode-验证与发布门禁).

## 📌 Project Status: Phase 1 & 2 Complete (MVP Ready)
**Date:** 2026-01-06
**Current Version:** 0.1 (Internal Alpha)

---

## 🏗 System Architecture Summary

### 1. Data Layer (SwiftData)
- **Model**: `Item.swift`.
- **Logic Engine**: `DataManager.swift` (Singleton-like via Environment).
- **Butler Engine Rules**:
    - **R1**: Sensitive items (Fresh/Medicine) without dates -> `actionRequired`.
    - **R2**: General items without dates -> Auto-duration.
- **Undo System**: 5-second window for Consume/Discard/Decrement.

### 2. Voice Input (The "Brain")
- **Tech**: `SFSpeechRecognizer` (Forced On-Device) + `NLTagger` (Local NLP).
- **Location**: `Services/VoiceManager.swift` & `Services/NLPParser.swift`.
- **Parsing**: Handles `[Quantity] + [Item Name]` patterns.

### 3. Vision Correction (The "Eyes")
- **Tech**: `VisionKit` (`DataScannerViewController`).
- **Flow**: Highlighting dates on packaging -> Tap to populate -> Confirm.
- **Date Parsing**: `Services/DateParser.swift` handles multiple packaging date formats.

### 4. Search & Extension
- **In-App**: Semantic fuzzy search in `DashboardView` (e.g., searching "吃的").
- **Core Spotlight**: Full system search synchronization.
- **Widgets**: `ButlerWidget` with Small/Medium sizes.

---

## ⚠️ Known Issues & Technical Debts

### 1. Widget Data Sharing (App Group)
- **Problem**: Currently, the Widget uses `PreviewData` because real SwiftData sharing requires an **App Group Identifier**.
- **Fix Needed**: In a real provisioning environment, need to:
    1. Enable App Groups in "Signing & Capabilities".
    2. Update `ModelContainer` to use a shared App Group URL.
    3. Update `WidgetCenter` to fetch from that shared store.

### 2. On-Device Speech Recognition
- **Note**: `requiresOnDeviceRecognition = true` is set. It may fail on old devices or if the specific language pack (zh-CN) isn't downloaded. Fallback logic is in place but needs real-world testing.

### 3. OCR Performance
- **Note**: Packaging can be busy. The `DateParser` is currently rule-based. If parsing fails frequently, consider a more robust regex or a micro ML model for date detection.

---

## 🚀 Next Steps (Priority List)

1.  **UI Polish**:
    - Add transition animations when an item moves from "Inbox" to "Urgency Grid".
    - Enhance the `ItemCard` with item-specific icons based on name.
2.  **Product Refinement**:
    - Implementation of "Storage Locations" (e.g., Freezer vs Pantry) selection in `ItemDetailSheet`.
    - Notification system: Push notifications when items are about to expire.
3.  **App Clips / Shortcuts**:
    - Add Siri Shortcuts for "What's expiring today?".

---

## 🛠 Troubleshooting for "Future Me"
- **Build Errors?** Check `Info.plist`. It's managed via `PlistBuddy` and contains Camera/Speech/Microphone permissions.
- **Data Not Refreshing?** `DataManager.saveChanges()` is the central point for `WidgetCenter` reloads and Spotlight sync. Always use this instead of `modelContext.save()`.
- **Scanner Not Working?** Ensure you are testing on a **Real Device**. Simulators do not support `DataScannerViewController`.
