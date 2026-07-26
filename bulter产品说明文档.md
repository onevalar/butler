# Butler MVP 产品说明（历史版本）

> 本文描述最初的 MVP 构想。Butler 2.0 的产品方向、领域模型、AI 执行协议、迁移约束与验收标准以 [`docs/BUTLER_2_SPEC.md`](docs/BUTLER_2_SPEC.md) 为唯一事实来源。

## 1. 产品概述 (Executive Summary)
1.1 产品愿景
Butler 是一款深度整合 Apple 生态的家庭库存管理助手。它旨在通过本地 AI (Local Intelligence) 解决传统库存管理 App“录入繁琐、隐私泄露、提醒机械”的三大痛点。它不是一个仓库管理员，而是一个注重隐私、极简高效的私人管家。

1.2 核心价值主张 (Value Proposition)
Zero Friction Input：语音优先，视觉辅助，极致降低录入成本。

Privacy First：所有计算（语音识别、OCR、语义分析）均在设备端（On-Device）完成。

Smart Triage：智能区分“高风险物品”（食品药品）与“低风险物品”（日用品），提供差异化的管理逻辑。

2. 用户角色与流程 (User Roles & Flows)
2.1 目标用户
家庭主理人：关注家庭物资储备，希望一眼看清库存。

独居青年/租房族：经常买菜但经常忘记吃，追求极简生活。

慢病/长期服药人群：需要严格管理药品有效期。

2.2 核心用户路径 (Critical User Journeys)
path A: 语音极速录入 (The Voice Flow)
用户通过 Siri 或 App 内按钮发起语音：“买了三盒牛奶和一包抽纸。”

系统识别实体 [牛奶, 抽纸]。

系统匹配知识库：

抽纸 -> 自动归档（默认1年保质期）。

牛奶 -> 识别为敏感物品且无日期 -> 进入[待补全]队列。

用户收到震动反馈，流程结束。

path B: 视觉补全 (The Vision Flow)
用户点击首页顶部的“待补全卡片（牛奶）”。

界面分屏显示：上半部分是相机/相册，下半部分是日期滚轮。

用户对着牛奶盒拍一张 -> 系统高亮日期 -> 用户确认 -> 归档。

path C: 消耗与撤销 (The Consumption Flow)
系统推送通知：“牛奶明天过期”。

用户长按通知 -> 点击“已喝完”。

系统扣减库存。如果误操作，用户可在 App 首页底部 5 秒内点击“撤销”。

3. 功能详细说明 (Functional Specifications)
3.1 核心对象模型：Item (物品)
每个物品必须包含以下核心字段：

Status (状态)：

Active (正常监控中)

ActionRequired (待补全信息 - 针对无日期的敏感物品)

Consumed (已消耗 - 历史记录)

Discarded (已丢弃 - 历史记录)

Type (类型)：Fresh (生鲜), Pantry (干货), Medicine (药品), General (日用).

Dates (关键日期)：

expiryDate: 绝对过期时间。

isEstimated: Boolean。如果是由 AI 默认规则生成的日期，为 True；用户手动确认过，为 False。

Evidence (存证)：localImageID (仅本地存储的原始图片引用，用于药品/配料表回溯)。

3.2 智能录入系统 (The Butler Engine)
逻辑规则 R1 (安全兜底)：凡是被分类为 Food 或 Medicine 的物品，若输入源未提供明确日期，必须标记为 ActionRequired，禁止自动填充猜测日期（除非用户明确说了“放冷冻”等延长指令）。

逻辑规则 R2 (懒人便利)：凡是被分类为 General (卫生纸、洗衣液) 的物品，若无日期，自动填充 Default_Duration (如 1 年)，并标记为 Active。

3.3 首页交互设计 (Dashboard UI)
Header：根据库存紧急程度动态变化的问候语。

Section 1: The Inbox：横向滚动的卡片流，仅展示 Status == ActionRequired 的物品。这是用户的“作业堆”。

Section 2: The Grid：Bento Grid 布局。

红灯区：剩余有效期 < 3 天。

黄灯区：剩余有效期 < 7 天。

绿灯区：其他安全库存（默认折叠或缩小显示）。

3.4 搜索与发现 (Search & Spotlight)
支持 Core Spotlight 索引。用户在 iOS 桌面下拉搜索“感冒药”，需直接显示 Butler 内的库存结果。

App 内搜索支持模糊语义：“找一下吃的”、“快过期的东西”。

4. 非功能性需求 (Non-Functional Requirements)
4.1 隐私与安全
Network Policy：默认不请求网络权限（除 iCloud 同步外）。所有 ML 模型必须离线运行。

Data Sovereignty：用户数据归属于用户的 iCloud 账号，开发者无法查看。

4.2 性能指标
Cold Start：冷启动时间 < 1.5秒。

Voice Latency：语音转文字并提取实体的处理时间 < 2秒 (iPhone 15 Pro 基准)。

4.3 兼容性
最低支持 iOS 17.0 (为了使用 SwiftData 和最新的 Vision API)。
