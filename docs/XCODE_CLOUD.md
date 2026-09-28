# Xcode Cloud 与 TestFlight

配置日期：2026-09-28。源码唯一分支为 `main`。

## 目标流程

云端修改并推送 `main` → 用户要求新测试版时手动启动工作流 → Xcode Cloud 测试与 Release 归档 → Apple 处理构建 → 分发给内部 TestFlight 测试组 → 手机安装/更新。

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
| 分发 | 成功后自动交给内部 TestFlight `test` 组 |

“App Store 分发准备”仅生成适合 Apple 分发的签名归档，不会自动提交正式商店审核或上架。外部测试另受 TestFlight 审核和分组控制。

## 配置进度

GitHub 仓库授权已完成，以上工作流已在 App Store Connect 保存并启用。首次初始化构建 1 已完成编译，但上传因构建号低于已有的 22 而失败；下一次构建号已设为 23，之后由 Xcode Cloud 递增。测试动作与内部组自动分发已补齐。

[查看工作流和实际构建结果](https://appstoreconnect.apple.com/teams/52049831-307a-44f3-95af-623b83d68dc0/xcode-cloud/products/ECE4419A-60C4-420A-A42F-FEB1AC95BFB8/groups)。后台配置完成不等于每次构建都会成功，应以该提交的测试、归档和 TestFlight 分发结果为准。

### 首次完整验证

2026-09-28，构建 23 手动验证成功；随后提交 `d11f06f` 自动触发构建 24，后台明确显示 `Code push`。构建 24 的 Test、Archive 和 TestFlight Internal Testing 三项均成功，版本 `1.0 (24)` 已进入内部 `test` 组，并带中文测试说明。真实手机安装与通知送达仍需测试者接受邀请后验证。

以上自动触发仅用于首次验证。按用户后续要求，现已移除 Branch Changes，只保留 main 的 Manual Start；不再每次推送都构建。正常提交不需要依赖 `[ci skip]`。

## 后续构建操作

用户约定：完成开发或“提交推送”不意味着需要新测试版。只有用户要求构建、发布测试版或更新 TestFlight 时，才启动云构建；不要为验证文档或配置变更重复构建。

1. 确认要分发的功能已提交推送到 `main`，记录提交 SHA；更新 `TestFlight/WhatToTest.zh-Hans.txt`。
2. 打开上述构建页面 → **Start Build** → **Main · TestFlight** → **Next** → 选择 **main** → **Start Build**。日常无需重新配置 Xcode、签名或仓库授权。
3. 确认构建对应预期 SHA。构建号由 Xcode Cloud 自动递增；仅当其他渠道上传过更高构建号时，再通过 Settings → Build Number 调整下一次编号。
4. 等待 Test、Archive、TestFlight Internal Testing 都成功，然后在 TestFlight 核对新版本属于内部 `test` 组。失败时先看对应日志，修复后再手动重试。
5. 向用户报告版本/构建号、提交、测试与分发结果。本人需接受邀请并在手机 TestFlight 安装或更新；外部测试分发仍单独处理。

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
