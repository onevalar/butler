# Xcode Cloud 与 TestFlight

配置日期：2026-09-28。源码唯一分支为 `main`。

## 目标流程

云端修改并推送 `main` → 用户要求新测试版时手动启动工作流 → Xcode Cloud 测试与 Release 归档 → Apple 处理构建 → 分发给内部和外部 TestFlight `test` 测试组 → 手机安装/更新。

TestFlight 是分发渠道；云端编译由 Xcode Cloud 完成。GitHub 上的代码必须先提交推送，再手动启动构建，手机才可能收到新版本。普通提交和推送不会触发云构建。手机和开发电脑不必连接；初始化完成后的构建也不依赖开发电脑在线。

## 仓库配置

- 项目：`Butler.xcodeproj`，共享方案：`Butler`。
- 应用标识：`com.anvalar.Butler`，Apple 团队：`H4982D35ZR`。
- `Butler.xcodeproj/xcshareddata/xcschemes/Butler.xcscheme` 纳入 Git，包含应用构建、全部 `ButlerTests`、Debug 测试和 Release 归档。
- 测试目标禁止并行执行，避免共用 UIKit 窗口和系统设置的测试互相干扰。没有跳过新增功能测试或为了云构建关闭断言。
- 无额外包管理器安装步骤；不向仓库放入证书、Apple 密码、GitHub 令牌、主模型凭证或 Jev 密钥。自动测试使用本地替身，不需要真实模型账号。
- 保留现有非豁免加密声明；Xcode Cloud 构建号由后台递增管理，启用分发前核对其高于已有 TestFlight 构建号。

## 后台工作流配置

| 项目 | 设置 |
|---|---|
| 名称 | Main · TestFlight |
| 触发 | 仅 Manual Start，指定 `main`；已移除 Branch Changes |
| 自动触发 | 无推送、PR、标签或定时触发 |
| 工具链 | 固定 Xcode 26.3；升级后先验证 |
| 测试 | iPhone 17 Pro，Xcode 26.3 对应的 iOS 26.3，Butler 全部测试，Required to Pass |
| 归档 | iOS，Butler，Release，App Store 分发准备 |
| 分发 | 同一 Archive 同时配置内部和外部 TestFlight `test` 组分发 |
| 干净构建 | Clean 开启，满足外部测试分发要求 |
| 编辑权限 | 按 Apple 要求限制为账户持有人、Admin / App Manager |

“App Store 分发准备”仅生成适合 Apple 分发的签名归档，不会自动提交正式商店审核或上架。内部和外部复用同一次归档，不会为两组重复编译。外部测试仍受 Apple Beta App Review 约束，因此配置同时分发不等于两组同时可安装。

## 配置进度

GitHub 仓库授权已完成，以上工作流已在 App Store Connect 保存并启用。首次初始化构建 1 已完成编译，但上传因构建号低于已有的 22 而失败；下一次构建号已设为 23，之后由 Xcode Cloud 递增。测试动作与内部、外部组自动分发已补齐。

[查看工作流和实际构建结果](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/groups)。后台配置完成不等于每次构建都会成功，应以该提交的测试、归档和 TestFlight 分发结果为准。

### 首次完整验证

2026-09-28，构建 23 手动验证成功；随后提交 `d11f06f` 自动触发构建 24，后台明确显示 `Code push`。构建 24 的 Test、Archive 和 TestFlight Internal Testing 三项均成功，版本 `1.0 (24)` 已进入内部 `test` 组，并带中文测试说明。真实手机安装与通知送达仍需测试者接受邀请后验证。

以上自动触发仅用于首次验证。按用户后续要求，现已移除 Branch Changes，只保留 main 的 Manual Start；不再每次推送都构建。正常提交不需要依赖 `[ci skip]`。

### 内外部双组分发（2026-09-28）

工作流保存并重新加载确认包含两个 Post-Actions，均使用 `Archive - iOS`：

- TestFlight Internal Testing → 内部 `test`（`abcf921d-805b-4c64-aa27-1b4e0f4c3e8b`）。
- TestFlight External Testing → 外部 `test`（`fc3975ec-6907-48e5-a8a7-ac0df7264279`）。

两组同名但不是同一组，检查时必须同时核对内部/外部类型。已有 `1.0 (24)` 已补加入外部组，提交时勾选 Automatically notify testers；后台现显示 Testing，并关联两组。手机通知和实际安装尚未验证。本次没有启动新构建；新的自动外部分发动作将在下一次用户要求的构建中验证运行结果。

## 后续构建操作

用户约定：完成开发或“提交推送”不意味着需要新测试版。只有用户要求构建、发布测试版或更新 TestFlight 时，才启动云构建；不要为验证文档或配置变更重复构建。

1. 确认要分发的功能已提交推送到 `main`，记录提交 SHA；更新 `TestFlight/WhatToTest.zh-Hans.txt`。
2. 打开上述构建页面 → **Start Build** → **Main · TestFlight** → **Next** → 选择 **main** → **Start Build**。日常无需重新配置 Xcode、签名或仓库授权。
3. 确认构建对应预期 SHA。构建号由 Xcode Cloud 自动递增；仅当其他渠道上传过更高构建号时，再通过 Settings → Build Number 调整下一次编号。
4. 发布前在 CloudKit Console 对照 Development/Production，确认本版使用的记录类型及索引均已部署；TestFlight 构建成功不代表数据库结构已发布。开发与生产数据隔离，不能用 Debug 同步成功代替生产验收。
5. 等待 Test、Archive、TestFlight Internal Testing 和 TestFlight External Testing 完成，然后在 TestFlight 核对新版本关联内部、外部两个 `test` 组，并检查外部审核/可测试状态。失败时先看对应日志，修复后再手动重试；不要把等待审核误认为需要重新构建。
6. 向用户报告版本/构建号、提交、测试与分发结果。测试者需接受对应组邀请并在手机 TestFlight 安装或更新；如外部仍待审核，分别报告内部可用和外部等待状态。

已跑通的构建 23/24 等待约 5～7 分钟，消耗约 7 计算分钟/次，仅作经验估计；Apple 排队和处理可能延长耗时。

## 测试说明

`TestFlight/WhatToTest.zh-Hans.txt` 随版本维护，Xcode Cloud 会自动将其附加为中文测试说明。后续功能变动时一并更新，避免测试者不知道应验证哪些行为。

## 手机端

使用已加入测试组的 Apple 账号打开 TestFlight，安装“小当家”。后续可手动更新或开启自动更新；构建、处理、审核和通知均不是即时的。每个 TestFlight 构建有效期最多 90 天。

## 排查顺序

1. 在 GitHub 确认修改已推送到 `main`。
2. 在 App Store Connect 的 Xcode Cloud 模块查看该提交的构建，检查测试/归档日志。
3. 构建成功后查看 TestFlight 是否仍在处理、是否有合规事项、测试组是否获得该构建。
4. 手机确认使用正确测试账号；必要时打开 TestFlight 手动刷新。
5. GitHub 源码授权失效、Apple 协议更新或签名权限问题需要账户所有者处理。不要将秘密粘贴进聊天或仓库。

官方参考：[首次工作流](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow)、[TestFlight 分发](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight)、[构建号管理](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)。

## 本轮发布记录（2026-09-29）

- 功能提交 `f58fd47` 已推送 main；构建25归档成功，但美国区域下两条时间断言失败，Required to Pass 正确阻止内外部分发。不要分发25。
- 修复提交 `85f14df` 明确首页24小时时间，并修正测试输入的区域/跨午夜依赖；本机英文美国区域348项测试，1项既有跳过，0失败。
- 手动[构建26](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/3580b058-d8ce-435e-91ce-752ae5f59592/summary)使用 `85f14df`。Test、Archive、TestFlight Internal Testing 均 Succeeded；中文测试说明自动保存。
- `1.0 (26)` 先进入 Pending Beta Review，随后审核通过，外部步骤自动变为 Succeeded。版本详情已核对 Groups (2)：内部 test（1人）、外部 test（2人），内外部分发完整跑通，无需手动补加构建。手机通知送达和实际更新仍由测试者确认。
- 本次构建页面最终时长约10分钟（另排队31秒），Usage为7计算分钟。本记录提交仅保存结果，不再触发新构建。

### 新增系统能力的签名要求（2026-10-01）

构建27在ba7b81a的编译阶段失败；发布修复已推送至04e5aa9，本机571项测试（1项既有跳过）0失败，Release编译通过。构建28完成归档编译，但签名导出失败，原因是Xcode Cloud不能自动注册新扩展或开启主应用的新能力。此类错误必须先补齐Apple Developer配置，再重试，不能用关闭测试或删掉entitlement绕过。

需要配置：

| 应用/扩展 | Bundle ID | 能力与容器 |
|---|---|---|
| Butler | com.anvalar.Butler | 保留WeatherKit；HealthKit、HomeKit、iCloud/CloudKit；iCloud.com.anvalar.Butler；以下两个App Group |
| 分享扩展 | com.anvalar.Butler.ShareExtension | group.com.anvalar.Butler.share |
| 闹钟/小组件扩展 | com.anvalar.Butler.AlarmWidget | group.com.anvalar.Butler.widgets |

用户已明确授权补齐这些能力。主应用四项能力已保存；两个App Group和iCloud容器已注册，分享扩展App ID已注册。剩余扩展注册与容器关联因浏览器网站访问权限被拒绝暂未完成；不代表已可TestFlight安装。待权限恢复继续补齐，并以最终云端签名/分发结果验证。

### Build 32 日志验证（2026-10-02）

用户补齐并保存Apple Developer配置后，Build 32的Test Build、Test Execute、Archive及Export均成功。四份用户提供日志确认571项测试、1项跳过、0失败；此前主应用、分享扩展、小组件的签名阻塞已不再出现。本段更新前文“待补齐配置”的状态。

本次附件没有TestFlight内部/外部Post-Actions最终结果，分发可用性仍须在后台核对。页面26/27条警告主要重复，完整清单与待实施修复计划见[Build 32警告修复计划](BUILD_32_WARNING_FIX_PLAN.md)。保存记录及计划不触发新构建。

### Build 37 发布（2026-10-08）

- 当前完整工作区提交 `444576d` 已推送 main，手动启动 Main · TestFlight；包括首页、天气抽屉、日期抽屉、物品卡片/搜索及水晶球形变优化。中文测试说明已更新并自动同步。
- [构建37](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/4d791bc5-4733-4bf3-abf8-5d808034ffcf/summary) 的 Test、Archive、Internal Testing 和 External Testing 均 Succeeded；外部经过 Pending Beta Review 后完成。测试页显示716/717通过，无失败；3条警告均为 WeatherStoreTests 未标记 loader 尾随闭包的弃用提示。
- TestFlight `1.0 (37)` 状态 Testing，已核对 Groups (2)：内部 test（1人）和外部 test（2人）。云端时长11分钟，Usage10分钟。手机安装/通知送达未验证。
- 本记录仅保存发布结果，不再触发构建。

### Build 39 编译失败及修复（2026-10-14）

- 整合提交 62e1ece 及真机 CloudKit 非法控制记录 ID 修复 9fb6469 均已推送 main；本机完整 779 项测试、1 项既有跳过、0 失败，Release 签名构建成功。
- 手动启动 [Build 39](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/0cc21281-4b0e-414e-854e-b95855eca882/summary)，后台核对提交为 9fb6469ee44f80658f58b7a18a061655e9481f7b，Xcode 26.3。Test 在 OrbDock.swift:398 报告 Ambiguous use of operator '-'，必过测试阻止内外部 TestFlight 分发。显式转换透明度参数为 Double 后重新构建，不能分发 39。
- 真机诊断明确拒绝旧控制记录 __control__，新编号修复已通过完整回归；手机重连后成功安装并启动，20:07:32、20:08:08 日志连续显示 pending=0; joining=false，真实云端写入恢复。第二个 iCloud 账号的真实邀请／双向验收仍待完成。

### Build 40（2026-10-14）

- 修复 Xcode 26.3 的透明度类型歧义与首页提醒有效期长表达式类型检查超时；提交 a6b70e5 已推送 main，手动启动 [Build 40](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/050b9c15-ac34-43b1-a891-ff7284ced1b6/summary)。
- 兼容修复后本机 79 项提醒与动效回归通过，另有 9 项邀请展示测试通过；最新 Debug 真机签名构建已覆盖安装（db sequence 2276）。之前云写入修复版已实测同步两次成功、待上传归零；最终等价编译兼容版安装后因手机锁屏未自动启动。
- 云端 778/779 通过（1 项既有跳过、0 失败），Test、Archive、TestFlight Internal Testing 均 Succeeded；External Testing 经 Pending Beta Review 后转为 Succeeded，内外部分发均成功。云端总耗时约 13 分钟，Usage 10 分 20 秒。4 条测试警告为既有 WeatherStoreTests 尾随闭包提示及远程通知代理的 Swift 6 隔离迁移警告。
- TestFlight 1.0 (40) 状态 Testing，已核对 Groups (2)：内部 test（1 人）、外部 test（3 人）；中文测试说明已自动带入。本记录提交只保存结果，不触发下一次构建。

### Build 40 发布后生产数据库修复

- 21:24 真机反馈 CKShare 创建失败；Production 缺 ButlerRevisionV1、ButlerSyncControlV1、cloudkit.share。已在 CloudKit Console 部署开发结构至生产，未删除或迁移用户数据。
- 21:40 用户确认“邀请家人”和“复制家庭链接”都恢复；真机日志证实系统邀请抽屉打开、有效 iCloud 链接复制。无需新版本或重新构建。
- 仍有开发安装切换 TestFlight 后的家庭历史不匹配问题，生产同步尚未验证恢复；前文 pending=0 仅为调试安装环境，不能代表两个环境的数据互通。必须保留防止旧数据复活的检查，并另行实现明确的环境切换／恢复方案。

### Build 41（2026-10-14）

- 按用户要求启动 [Build 41](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/b04310b0-65a3-4214-8959-c7386f40a0a9/summary)，核对源码为 `999d6218c1111f545163322b821dac680348f243`。包含单人邀请、App 直达／粘贴接收入口，以及显式备份后恢复生产家庭同步；创建者手机的生产恢复已验证，真实跨账号加入及双向同步仍需双方更新验收。
- 云端 Xcode 26.3：788/789 测试通过，1 项既有跳过，没有失败。Test、Archive 均 Succeeded；归档日志确认 app-store 分发签名及上传准备通过。4 条测试警告和1条归档警告仍为既有 WeatherStoreTests 尾随闭包、远程通知代理 Swift 6 隔离迁移提示。
- 安装包于23:39进入 TestFlight，自动分发 Post-Actions 长时间排队，因此直接在 TestFlight 保存本次中文说明、关联现有内部 test（1人）及外部 test（3人），勾选 Automatically notify testers 并提交 Beta Review。未启动第二次构建，未提交正式 App Store 上架。
- [1.0（41）](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/apps/6815130996/testflight/ios/84ca76eb-3bd9-41a7-aa18-42d3110d4fae) 已显示 Testing，Groups (2) 已核对；外部组 Builds 中同样为 Testing，且已有外部测试者安装41的回执。该状态确认 TestFlight 已可分发，不表示家庭邀请跨账号验收完成。最终核验时云工作流的自动分发动作仍排队，不将手动发布成功记成它们已成功。
- 发布截图保存于 `build/testflight-release-41/external-testing.jpg`（本地构建资料，不纳入源码）。本记录仅保存结果，不触发新构建。

### Build 42 / 43（2026-10-15）

- 对话布局、键盘定位、模糊时间修改、家庭确认卡及模型选择修复 `3ab73c3` 与测试说明 `b450b0e` 已推送。用户明确要求新 TestFlight 后启动 Build 42；云端 Xcode 26.3 在 `SubscriptionModel.swift:110` 拒绝带参数的隐式初始化，测试与归档失败，未分发42。
- 提交 `07cfe86` 为流解析器及模型配置补上显式初始化，保持默认模型和选择语义；本机 SubscriptionModelTests 回归通过。随后手动启动 [Build 43](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/9fff14da-c8c6-46e7-b1b6-4cc141c39466/summary)，后台核对源码 `07cfe86da67be6a88856bb1dc5bc0dd9405ca8d6`。
- 云端 Test、Archive、TestFlight Internal Testing、TestFlight External Testing 全部 Succeeded。测试794/795通过，1项既有跳过、无失败。4条警告为 WeatherStoreTests 的3处 loader 尾随闭包标注及 HouseholdInviteHandler 的 Swift 6 Sendable 迁移提示；本版没有更改这些位置。
- [1.0（43）](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/apps/6815130996/testflight/ios/21fa76a9-299d-403a-8438-11f53f49dd10) 已自动进入内部 test（1人）、外部 test（3人）；外部组显示 Testing，本次中文测试说明已自动带入。发布截图在 `build/testflight-release-43/external-testing.jpg`。测试者仍须在手机 TestFlight 更新；该发布结果不等于真实跨账号家庭同步验收。
- 本记录仅保存发布结果，不再触发新构建。

### 家庭身份编辑与首页摘要：Build 44（2026-10-15）

- 发布提交 `9ef152e` 已推送 `main`，包含家庭名称编辑、个人显示名字与本机称呼分离、同名歧义处理及首页安静摘要；本版不新增 CloudKit 类型、字段或索引，家庭名称使用既有 CKShare title，个人称呼不进入共享数据库。
- [Build 44](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/builds/f0137000-cabf-4595-b8d7-ccb7748cb184/summary) 的 Test、Archive、TestFlight Internal Testing、TestFlight External Testing 全部 Succeeded。云端799/800通过，1项既有跳过、无失败；警告仍为 WeatherStoreTests loader 闭包标注与 HouseholdInviteHandler Sendable 迁移提示。
- [1.0（44）](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/apps/6815130996/testflight/ios/fe564a54-3d4c-4db6-a15a-7ca2758d7801) 状态 Testing，内部 test（1人）、外部 test（3人）均已关联；外部组 Builds 中同样为 Testing，中文说明已核对。发布凭证：`build/testflight-release-44/external-testing.jpg`。
- 手机可从 TestFlight 更新。发布成功不代表已完成真实跨账号改名同步验收；此前本地安装尝试因手机连接中断未成功。
