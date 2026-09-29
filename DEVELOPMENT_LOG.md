## 对话输入栏按“信息”App 的样式重做
**Date:** 2026-09-29 · 手机实测反馈（上一版输入框文字不居中、尺寸没对齐、右侧按钮突兀）

- 参照系统“信息”：左侧 40pt 圆形“＋”，右侧胶囊输入框与“＋”同高（40pt），文字单行时垂直居中，换行时向上长高，“＋”贴底对齐。
- 右侧只有一个不带底色的图标：空白时是波形（开始语音），有文字时是实心蓝色 ↑（发送），听写中红色停止，准备/收尾时小转圈；去掉上一版的灰色圆底和“文字满行后按钮另起一行”的做法。
- 有文字时不再显示“用语音补充”的话筒（与“信息”一致）；补充说话可先发送，或用首页水晶球。
- 模拟器深色模式核对空白与两行文字两种状态；全量测试通过。

## 对话输入栏重做：按钮变小、长文字占满宽度、语音状态只有一个图标
**Date:** 2026-09-29 · 手机实测反馈

- 两侧 52pt 大圆按钮改小：左侧“＋”40pt；发送/话筒/停止改为输入框内右下角 32pt 小圆按钮，输入框本身变宽（高 44pt、圆角 22）。
- 文字一旦超过一行，输入框切换为“文字占满整行、按钮单独一行在下面”，最多 10 行后滚动；清空后回到单行。原来文字被右侧话筒挤成一窄列的问题消失。
- 语音状态：准备中 / 收尾中只显示一个转圈（点它取消或保留文字），听写中是红色方形停止键，原来“转圈 + 底部小叉号”的叠加去掉；输入框上方重复的“正在听写…”提示去掉，只保留输入框里的提示文字。
- 模拟器核对长文字换行布局；全量测试通过。

## 首页与对话细节：“其他”并入按钮行、日期改纯文字、纸箱图标、天气面板重排、对话顶部拆开
**Date:** 2026-09-29 · 手机实测反馈

- 管家卡片：右上角“其他安排”取消，改为按钮行最后一个玻璃按钮“其他”（行为不变：打开整张提醒的独立对话）；没有快捷按钮的提醒也有“其他”。
- 左上角日期：去掉液态玻璃底和边框，只是文字加小箭头，点按区域不变。
- 物品入口图标改为 Paper「v13 物品页」方案 B（敞口纸箱）。
- 天气详情：改为带手柄的上拉面板（半高/全高），去掉“完成”和“手机定位”标题。顶部卡片：大天气图标 + 温度 + 天气，下面一行体感/风速；提示与预警；底部一行“位置 · 几点更新”和刷新按钮。未来几天改为“今天/明天/周几”、降水概率≥20% 才显示、低温/高温对齐。天气位置改为一张卡：使用手机定位（选中打勾）/ 已选城市 / 搜索框 / 搜索结果，说明和“打开系统定位设置”放在卡片下方小字。Apple Weather 标识缩小放在最底部。
- 对话顶部：去掉左上角没有作用的小水晶球；“更多”移到左上角，关闭保留在右上角，两者分开。
- 模拟器核对首页、天气面板（上下两段）、对话顶部；全量测试通过。

## 物品页顶部单层背景、语音收尾的取消离水晶球更远
**Date:** 2026-09-29 · 手机实测反馈

- 物品页右上角切换控件外面又套了一层工具栏玻璃，显示成两层；去掉工具栏那层，只留切换控件自己的底。
- 自定义语音服务收尾时，“正在整理语音…”、“取消识别”和水晶球上下挤在一起，取消很难点准。改为一个胶囊“⟳ 正在整理语音… | 取消”，整体离水晶球多留约 40pt，取消是完整 44pt 点击区域；出错时的“知道了”也加大并离球更远。
- 语音转写失败排查：手机日志显示本次更新前（17:21）就已出现“实时服务会话建立后没有返回文字”的情况，更新后同样是会话建立需 4～5 秒、之后没有结果或连接被中断；本次改动没有涉及录音和转写代码，判断为实时转写服务/网络问题。

## 对话面板说话后改为约 3/4 高
**Date:** 2026-09-29 · 手机外观反馈

- 半高显示的对话内容太少：按住水晶球说话后，面板改为停在屏幕约 3/4 高度，顶部仍露出原页面（可看到方块数字变化，也可滑动）；打字仍为全高，往上拉全高、往下拉收起不变。

# Butler Project Development Log & Handover Notes

## 物品页改版与统一的对话面板
**Date:** 2026-09-29 · 本地开发，按 Paper「v13 物品页」实现

- **入口与标题**：首页右上角的柜子图标换成百宝箱图标（箱子里冒出瓶子、小球和一点闪光）；“家里”改名“物品”，首页底部那行也改为“物品 N 样”。
- **物品页**：返回、标题“物品”和“分类 / 位置 / 到期”三个切换合成一行，下面是每行两个的大方块（图标、名字、数量、前三样东西的名字；有过期、三天内到期或快用完的东西时右上角角标，已过期或用完为红色）。点方块进入只有这一组的列表；列表行改为小图/分类图标 + 名字 + 一个人话状态（“还有 2 天”“已过期 4 天”“剩 6 瓶”），去掉左侧色条和重复的数量。副标题、示例话、搜索框、＋ 全部去掉；“已处理的东西”是最下面一行入口。切换方式会被记住。
- **统一的对话面板**（用户确认）：全 App 只有一张从底部升起的对话面板。按住水晶球说话 → 停在半高，上半屏还是原页面且可以滚动；要打字（轻点水晶球、其他安排、点输入框）→ 全高。往上拉看完整对话，往下拉收起。
- **清单卡**：管家列出的东西以“标题 · N 样”的卡片显示，每行写数量、位置、临期状态和一句理由；点行打开详情，点 × 只从这张清单去掉（东西还在家里）。
- **手机上直接回答**：“我有什么衣服”“冷藏里有什么”“螺丝刀放哪了”“什么快过期了”这类单一对象的问题在手机上立刻列出，不等模型，未登录也能用；“修自行车要用什么”“野餐带什么”等需要判断的仍交给模型。清单显示时说“去掉某样”也在手机上直接处理；说不清是哪一行时交给模型。
- **模型新工具**：`update_shown_list`（就地改最近显示的清单）、`propose_regroup`（一次把多件东西改位置和/或分类，每件一条待确认）。当前显示的清单会作为上下文发给模型；以前对话里显示过的清单名称也写进历史。
- 测试：新增 `ItemsPageTests` 10 项（方块分组与角标、各切换覆盖全部东西、手机直答与交给模型的边界、去掉清单行、清单就地修改、批量调整需确认）。全量 358 项通过、1 项原有跳过。模拟器核对了物品页三种切换、进入分组、打字全高、手机直答和 ×、面板拉到半高后上方页面可见；按住说话后自动停在半高需真机确认。

## 首页日期浏览、后台建议与完整清单
**Date:** 2026-09-29 · 基于 `dabdbd3` 的本地交互修订，尚未发布

- 日期胶囊打开完整面板，支持过去/未来翻月、指定年月日和全部任务历史；左右滑动不再限制从今天起，清单以当天记录/当天安排标明归属，返回今天使用文字按钮。非今天收起实时建议和本周/家里摘要。按浏览月份补算日程并查询已授权系统日历，不计算跨年间所有日期；前后台切换保留用户选择的历史日期。
- 移除四条截断及已完成折叠，清单全量显示；无时间的行去掉空时间栏，长标题与状态换行，日期控件中文化。保留新近的紧凑建议卡和长按说话实现，没有回退这些设计。
- AI 建议后台运行，当前操作不禁用，使用“小当家正在更新…”文字。用户触碰后锁定本轮可见卡片，背景结果继续缓存，不在手指下切换内容；无候选使用中性文案，不再断言全部完成。
- “先放放”先弹出时间选项（1 小时、明早 9 点、3 天后 9 点、自选时间），取消不保存，说明仅暂停首页推荐而非任务通知。首页不加即时撤销条。
- 任务管理默认显示全部状态，增加搜索；已完成/取消任务可在详情显式恢复未完成，保留 ID 与历史、递增版本并清除已过期自动完成时间，普通 resume 仍不能复活结束任务。
- 验证：首轮全量串行 280 项，279 通过、1 项原有迁移跳过；后加的任务纠正专项 16 项全部通过；最终中文日期、提示文案、整页滑动及前后台日期保留调整后模拟器 Debug 构建通过。日志 /private/tmp/butler-home-interactions-tests.log、/private/tmp/butler-task-correction-tests.log、/private/tmp/butler-home-interactions-final-build.log。
- 原生模拟器验证日期面板过去日期可选、9 月 27 日任务保留、明天不混入今日建议、返回今天、“先放放”时间面板布局及中文日期。自动化拖动未能可靠验证实际左右滑动，仍需真机手势验收；云模型后台竞态通过替身测试，未做真实账号网络及日历授权验收。未提交推送或启动云构建，未更新手机/TestFlight。

## 两张卡片的内容与排版：确认卡说人话，管家卡片更紧凑
**Date:** 2026-09-29 · 本地开发（手机实测反馈）

- **确认卡**：去掉左侧蓝色竖杠。任务计划的说明由原来的整套规则（时区、阶段编号、“多个时间或次数限制以最先达到的为准”、最多 6 次预览等）改为几句人话（`friendlySummary`）：例如“今天 20:00 提醒一次”“第 1 段：今天 18:00 起，每 10 分钟提醒，最多 6 次”“1月4日 20:00 之后不再提醒”，只有时区与本机不同才提一句。完整规则仍在任务详情页和给模型的内容里。暂停/完成/取消任务的确认卡不再附加“将应用到这个任务，保留历史记录”。
- **管家卡片**：文字从 22 号粗体改为 17 号中等字重，并撑满卡片宽度（之前被按钮行的宽度带窄）；问候行右侧放“别的安排 ›”（原来占一整行的底部说明取消）；内边距和按钮略收，整体更紧凑。模型可以写一到两句、总共不超过 60 字：先说重点这件事，再顺带提一句别的；本机拼的句子也会在末尾补“另外 A、B 也要留意”。
- 测试：新增确认卡人话摘要 3 项、本机卡片补充句 1 项；原“确认卡包含全部规则”的测试改为“说清每一段和边界，且不含内部规则文字”。全量 277 项通过。

## 长按说话：去掉重复文案，理顺取消区形状
**Date:** 2026-09-29 · 本地开发（手机实测反馈）

- 文案：原来最多叠三层（“…”气泡、提示胶囊、红色区里的“✕ 取消”）。现在同一时间只有一处文字：上方一个气泡（没听到时“说吧，松手就发送”，听到后是识别文字），取消只写在红色区里，进入后变“松开取消”；手指在红色区且还没听到内容时不再显示“松手就发送”。提示胶囊取消。
- 形状：颈部由中间细的“工字”改成柱状（圆锥形，底部略宽、顶部略窄），红色区收窄成 96×58，触达高度 100；修掉圆条底边正中因平滑并集产生的小凸起（颈部底圆缩小）；红色渐变一直延伸进圆条上半部，衔接更连贯。
- 模拟器浅色截图核对，全量测试通过。

## 首页简报卡片：去掉“依据”，“其他”改为安静的文字入口
**Date:** 2026-09-29 · 本地开发

- 管家那句话下面不再显示“依据：家里的 N 样东西 · N 条提醒”。
- 原来和话筒图标放在一起的“其他…”按钮取消：按钮行只留模型为这件事挑的 2 到 3 个处理按钮；卡片底部改成一行不带按钮外观的文字“都不合适？告诉我你的安排 ›”，点开仍是只关于这一件东西（或这个任务）的独立对话，可以打字，也可以在对话里用话筒。没有具体事项的安静日子，卡片只有一句话，没有这一行。
- 模拟器浅色、深色截图核对；全量测试通过。

## 按住水晶球说话：即时反馈、先录后识别、连成一体的取消区
**Date:** 2026-09-29 · 本地开发，按 Paper「v12 长按说话」实现

- **形状**（`VoiceGeometry` / `VoiceGlass`）：按下即出现玻璃圆条（两头半圆），按住约 0.12 秒（原 0.35 秒）开始收音并拉宽到 176pt，两侧有随真实音量起伏的声条，页面变暗，上方是文字气泡和提示。识别还没有文字时显示小“…”气泡。上滑时红色取消区从同一块玻璃长出（三个形状的平滑并集，含颈部），随手指出现和收回；手指进入红色区并松手才取消，往下和左右滑不影响，滑回来收回。轻震：按下一次、进入/离开红色区各一次、松手一次。球背后的圆盘（对话页顶部小球的系统工具栏玻璃底）已去掉。抽出公用的对称轮廓追踪（`SymmetricContour`），水滴物理的原有行为和测试不变。
- **先录后识别**（`LiveDictation` / `AudioRelay`）：授权后先启动麦克风并把声音存起来，识别器在后台就绪后先按顺序补入已录的声音，再直接接上实时声音；松手时会等识别器追上再收尾。识别器不可用时回退到系统识别，同样补入已录声音。对话输入框里的语音按钮共用这一实现，同样受益。本地诊断日志新增三个时间点（收音开始、识别追上、第一批文字，相对于请求），在手机上可读取核对。
- **轻点保护**：按住不到 0.4 秒就松手且什么都没听到，按轻点处理，打开对话，不弹“没听清”。
- **测试**：新增 11 项（轮廓一整块、半圆端点、颈部、取消区各程度都不分离、只有上滑生效、进出红色区的回差、慢点判断、先存后补的顺序、跨线程不乱序）；全量 273 项通过、1 项原有跳过。测试中发现新增的音频中转类在非主线程释放会崩溃（与项目已知的 Swift 默认主线程释放问题一致），已显式声明 `nonisolated deinit`。
- **未验证**：模拟器没有真实说话声，只验证了形状、手势、提示和取消流程；真机上的按下到能说话的实际耗时、识别追上的速度、震动手感、深色和减少动态效果下的表现，需要在手机上测试并读取诊断日志。

## 首页改版：管家一句话、当天清单与三套主题
**Date:** 2026-09-29 · 本地开发，按 Paper「v11 定稿」实现

- **首页结构**：去掉一周日期条、小时时间轴、「需要处理 / 接下来」分区和“缺信息”提示，改为三层：管家的一句话（带按钮）、当天一张清单、两行安静入口（“这周还有 N 件”“家里 N 样”）。左上角日期胶囊点开是玻璃月历（有安排的日子有小点，过去的日子不可选），下面有“日程总览”“任务与历史”两个入口；选了别的日子后胶囊变成“9月30日 周三 ×”，点 × 回今天；清单左右滑动也能逐日切换。右上角三个图标：日历、家里（柜子）、设置。任务与历史入口因此从右上角移进日期面板，并保留在设置的“提醒与日程”里。
- **当天清单**（`HomeList`）：今天先列要处理的（过期、已到时间未完成的任务、三天内到期、快用完），再列当天的日程；其他日子先列全天的，再按时间。晚上 18 点后追加明早 10 点前的安排。管家一句话已提到的那件不重复列出；超过 4 件折叠成“还有 N 件，展开”；已完成的任务收在“已完成 N 件”里。已到时间待完成、已完成记录、任务生命周期沿用原有数据，没有改动。
- **管家一句话与按钮**（`ButlerBrief` / `BriefService`）：候选事项按紧迫度取前 5（过期 > 到时的任务 > 快到期 > 快用完）。登录后请求云模型挑一件、写一句话，并按这件事的实际情况给 2 到 3 个按钮。按钮效果限定在封闭集合内（处理这件东西为吃完/扔掉/送人、用掉几个、先放放 N 天、完成任务、稍后再提醒 N 分钟、打开详情），模型的回复经校验：目标必须是候选、效果必须适用于该对象、参数有范围，不合格的部分丢弃或整条回退。模型从不自己改数据，只有用户点按钮才执行（药品会再确认一次）。最后一个固定按钮“其他…”打开只属于这一件东西（或这个任务）的独立对话，键盘直接可输入，也可以用话筒，避免新交代的事和别处冲突。没登录、断网、超时（15 秒）或回复不合格时，用本机拼出的句子和默认按钮，等待期间按钮变淡不可点，防止点击时突然换掉。同一情形（事项、时段、日期）只问一次，结果缓存 8 小时；“先放放”记在本机，到点后再提。
- **主题**：设置 › 外观 新增“主题”（雾面默认 / 窗边的光 / 素净），背景带极细颗粒质感；卡片改为更通透的玻璃。原“背景光”开关并入主题：旧开关关闭的用户迁移为素净；设置工具的 ambientGlow 换成 appTheme，备份兼容旧字段。设置页各组改成一行一项，点开进入各自的子页（对话模型、Jev、到期提醒、定时提醒、系统日历、备份），原有开关和登录流程不变，列表页统一使用玻璃行。
- **性能**：首页一年的日程只在库存、任务、日历或分钟变化时重建（大户型 200 件加 40 个任务，在模拟器 Debug 下约 0.5 秒，缓存后不再随页面切换重复计算）。
- **测试**：新增 `ButlerBriefTests`（候选排序与先放放、本机句子、模型回复的白名单与参数校验、按钮真的改库存并由下一件接替、任务按钮、服务对成功/无效/断网/超时/过期回答/已缓存的处理、当天清单各排序规则、两行入口）和年日程耗时测试；原 DailyBrief 组合句测试随该功能移除。全量测试通过。
- **已知**：模拟器里 UserDefaults 曾被测试写成深色，看浅色需加启动参数 `-appearanceMode light`；未做真机上的模型实测（模拟器未登录）、话筒和真机动画体验。

## 完成记录保留与禁止水晶球环形进度
**Date:** 2026-09-29 · 本地修复，尚未发布

- 首页与全年日程使用持久任务记录；已完成任务保留在首页“已完成”区和全天时间轴，使用勾选、划线和淡化状态，仍可打开详情及相关对话。未完成任务到时仍留在待办，完成不删除数据，也不继续发提醒。
- 一次性任务保留原计划时间，跨日完成在实际完成日另有记录；提前完成不留下未来待办。周期和分阶段任务只展示整个任务的一次完成，不将历史通知当成多次完成；有完成记录的过去日期允许从月视图进入。
- 按用户明确要求，彻底移除水晶球按压进度圈、准备阶段旋转圆弧及其进度状态。保留球体形变、球内麦克风和真实音量声条。永久设计约束写入 Butler/Design/AGENTS.md，并同步功能说明和 TestFlight 验收项目。
- 本地模拟器构建及完整串行测试通过：246 项，245 通过、1 项原有迁移跳过、0 失败。覆盖完成持久化重读、原计划时间、跨日与提前完成、重复/分阶段任务去重、简报状态区分。日志：/private/tmp/butler-completion-tests.log。
- 未做本轮真机动画或麦克风体验验收；未提交推送，未启动 Xcode Cloud，未更新已安装版本或 TestFlight。

## 开关对比度、未完成任务保留与水晶球反馈
**Date:** 2026-09-28 · 本地修复，尚未发布

- 复现玻璃主题深色模式开关开启后轨道与滑块同为白色的问题。根级应用系统 SwitchToggleStyle，使用独立的中性轨道色，其他主题继续使用主题色，保留系统切换与辅助功能行为。
- 首页和全年时间轴改为读取任务持久记录，不再用“是否还有下一次提醒”决定是否显示。当天已到时间的任务置于“已到时间 · 待完成”，重复通知按任务合并；通知计划耗尽的往日未完成任务带原日期保留在今天。已完成任务保留完成记录，暂停、取消退出活动日程，不额外发通知。
- 简报明确列出已到时但尚未完成的任务；前台每 30 秒刷新日程，跨日更新所选日期及提醒状态。
- 水晶球下落接触点保留下落速度，横向展开提前衔接，消除两个分段缓动之间的速度断点。原有连续液面、反向和减少动态效果行为保留。
- 长按加入中央按压可见形变、即刻球内麦克风（环形进度方案已按用户要求彻底移除）、准备录音提示、实际收音声条；移除突兀的大范围光晕。准备期间明确“松开取消”，震动在麦克风真正开始监听时触发，声条使用真实音量。
- 验证：全量串行测试 242 项，241 通过、1 项原有迁移跳过、0 失败。新增到时/跨日/有限阶段任务保留、完成状态、重复提醒去重、接触速度连续回归（本段测试为 9 月 28 日结果，后续验证见最新条目）。最后仅补待完成行原提醒时间，Debug 模拟器构建通过。日志 /private/tmp/butler-feedback-full-tests.log、/private/tmp/butler-feedback-ui-build.log。
- iPhone 17 Pro / iOS 26.2 模拟器实际复现原深色开关异常，并确认修复后白色滑块与灰色轨道分离，开关状态正常。未做真人麦克风输入、真机帧率或动画手感验收；动画连续性通过几何回归测试验证，仍需手机体验。未提交推送、未启动 Xcode Cloud、未更新 TestFlight。


## Xcode Cloud 内外部双组分发
**Date:** 2026-09-28 · Main · TestFlight

- 工作流新增 TestFlight External Testing，指向现有外部 test 组；保留内部 test 分发，两者复用 Archive - iOS。保存后重新加载确认两个分发动作和 Apple 强制编辑权限限制均已生效。
- 仍仅允许手动从 main 启动，无提交/推送触发；保留 Required to Pass 和 Clean。外部审核可能导致两组可安装时间不同。
- 已有 1.0 (24) 补加入外部 test 组并开启自动通知，后台已显示 Testing，关联内部及外部两组。未验证手机通知送达或安装。
- 本次未运行新构建；自动外部分发动作将在下次用户要求的构建中验证执行结果。操作和排查更新至 docs/XCODE_CLOUD.md。


## 云构建改为按需手动启动
**Date:** 2026-09-28 · 用户要求节省构建额度

- Main · TestFlight 已移除 Branch Changes，只保留 Manual Start，分支限定 main；没有自动推送、PR、标签或定时触发。
- 保留已验证的测试、Release 归档、签名和内部 test 组分发。本次未启动新构建，最新已分发版本仍为 1.0 (24)。
- 用户要求“提交推送”时只提交推送；明确要求构建或更新测试版时才手动启动。操作步骤、构建号和失败排查已写入 docs/XCODE_CLOUD.md。


## Xcode Cloud 自动构建与 TestFlight 内部分发
**Date:** 2026-09-28 · main · Xcode 26.3 / 云端 iOS 26.3

- 已共享 Butler Scheme，包含完整串行 ButlerTests 和 Release 归档；本机验证 237 项：236 通过、1 项原有跳过、0 失败。
- 所有者完成 GitHub 授权。后台工作流 Main · TestFlight 监听 main 全部文件变更，自动取消同分支旧的同类构建，测试 Required to Pass，成功后分发内部 test 组。保留干净构建，不需要真实模型密钥。
- 初始化构建 1 在上传阶段因旧构建号失败，已将后续起始号改为 23。构建 23 完整验证成功；提交 d11f06f 自动触发构建 24，来源 Code push，Test、Archive、TestFlight Internal Testing 全部成功，1.0 (24) 已出现于 TestFlight 并关联内部 test 组。
- 加入 TestFlight/WhatToTest.zh-Hans.txt，云端确认保存中文测试说明。使用和排查方法见 docs/XCODE_CLOUD.md。
- 当前所有者内部测试邀请仍为 Invited，需本人在手机接受邀请。未声称已完成真机安装验收，也未自动分发给外部组或提交正式商店审核。


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

## 2026-09-29 通用物品与混合交互能力

- 对话待确认队列跨轮/重启保留；本机明确确认、取消与按序号选择；主模型可修改提案但无提交工具。执行前检查库存版本，已有任务/设置保持版本校验。按钮与语音共用业务服务。
- 补齐任务 reopen、库存历史/撤销工具。库存增加每批次的分类、属性、用途、可用状态和照片，资料修改经过 InventoryPolicy/Repository，保留事件和备份。家里分类浏览、属性搜索、资料编辑、对话图形结果清单贯通。
- 新增 WeatherKit 天气服务、前台大致定位、手动选城市、缓存、过期/失败/来源显示与工具。首页提示及后台摘要消费新鲜天气；天气城市改变后旧响应不能覆盖新选择。备份 v3 兼容旧数据。
- 回归测试首轮 293 项：292 通过、1 项旧迁移测试跳过、0 失败。后续界面检查发现的分类与视觉细节继续修正；最终验证见下条。
- 未提交推送、未触发云端构建。WeatherKit 开发者账户配置最初受浏览器访问授权阻挡；用户随后明确授权并完成登录，账户配置结果见下条。真机天气联网验证尚未完成。

- 最终相关回归：52 项全部通过，日志 `/private/tmp/butler-unified-final-tests.log`；前述全量 293 项无失败。`git diff --check` 通过。模拟器实际检查了升级后的原库存列表、物品资料分类选项、天气入口/首次定位提示、天气失败状态；手动搜索“上海”返回“中国上海市”。没有完成真实天气、真实主模型穿搭或真机验证。

- WeatherKit 账户配置（2026-09-29）：通过内置浏览器为 `com.anvalar.Butler`（团队 `H4982D35ZR`，App ID 记录 `G8X4DJNT2C`）分别启用 Capabilities / App Services 中的 WeatherKit，保存后重新打开确认两处均保持勾选。Apple 提示须重新生成关联的 provisioning profiles；项目 Debug/Release 已配置自动签名及 WeatherKit entitlement。未启动构建、安装或分发，实际天气请求留待新签名版本真机验证。确认截图：`/private/tmp/butler-weatherkit-enabled.png`。

- 随后按用户要求直接安装真机（2026-09-29）：当前 `main` 工作区的 Release 构建成功，通过自动签名取得包含 WeatherKit 的新描述文件，已核对安装包签名和描述文件中 `com.apple.developer.weatherkit = true`，且包含目标 iPhone。已更新安装并启动连接的 iPhone 14 Pro 上的 `com.anvalar.Butler`；本地版本号仍为 `1.0 (1)`，不对应 TestFlight 云构建号。安装前已备份 Documents、Application Support 和 Preferences 到 `/private/tmp/butler-iphone-before-weather-20260929`，包含原数据库及其 WAL/SHM。构建日志 `/private/tmp/butler-weather-device-build.log`。未提交推送或触发 TestFlight / Xcode Cloud。

- 真机天气验证通过：用户在手机打开天气、允许定位后确认显示城市、温度与未来天气；随后从应用自己的 Preferences 核实 `weatherSnapshot` 为手机定位模式，2026-09-29 14:02:21（Asia/Shanghai）取得新数据，观测时间 14:02:17，包含 7 天预报、Apple Weather 法律来源链接和明暗来源标识。检查仅输出天气元数据，不输出坐标或其他偏好。核验文件 `/private/tmp/butler-weather-device-verified.plist`。本次覆盖本地签名安装→手机定位→WeatherKit 实际请求→页面显示→缓存保存；手动城市切换的真机流程、TestFlight 分发及真实模型穿搭仍未在本轮验证。

## 2026-09-29 真机反馈后的首页交互纠正

- 根因：把清单局部浏览日期用作整个首页的显示条件，使滑动隐藏今日建议和底部摘要；又将天气派生提示与署名机械地插入卡片，混淆正文层级。此节与更新后的首页 AGENTS / 设计文档取代本日早期“非今天隐藏实时卡片”的方案。
- 日期状态明确命名为 `listDay`。左右手势只绑定清单，清单标题同步日期并就地提供“回到今天”；顶部日期锚定今天，今日管家卡片、天气、入口和底部摘要持续保留。完整日期面板仍可选任意日期，只更新清单；所有清单记录完整展示。
- 删除卡片内天气小字提示和来源区，署名保留在卡片外页脚和天气详情。普通天气不进入主动摘要上下文、不触发额外模型更新；删除仅依据昼夜温差提醒穿衣的规则。值得留意的新鲜天气作为可选线索，由主模型判断相关性并融入同一正文，无关就不提。中文条件名称覆盖 WeatherKit 全部现有枚举及旧英文缓存。
- 相关回归 39 项全部通过（Brief / HomeAgenda / WeatherStore），包含普通天气与正常昼夜温差不提醒、异常天气可用但旧天气不可用、旧英文缓存中文显示；日志 `/private/tmp/butler-home-local-browse-tests.log`。模拟器通过与滑动共用的无障碍前后一天动作验证昨天/明天切换、回到今天和稳定首页结构，截图 `/private/tmp/butler-home-browsing-tomorrow.png`；电脑自动拖动未能可靠触发模拟器手势，因此不将它作为触控手势验收通过的证据。
- Release 真机构建通过（`/private/tmp/butler-home-local-browse-device.log`），已更新安装用户的 iPhone 14 Pro；自动启动被手机锁屏阻止，已告知用户解锁后打开，真实左右滑动手感待用户确认。未提交推送、未触发云构建或 TestFlight 分发。
- 用户随后反馈“仍有整页变化或滑动不正常”，因此本轮真机交互验收未通过，不能把上述模拟器状态切换等同于修复完成。已追问具体是能翻日但其他区域移动/消失、滑动无法翻日或误触竖向滚动、还是两者都有；待明确表现后继续修复。

- 用户进一步定位：往过去正常，往未来误进任务详情，返回后又跳到更早日期。针对原 `simultaneousGesture` 与行 Button 可同时响应的冲突，新增 `HomeDaySwipe` 原生方向识别与 `HomeDayInteraction` 单次触摸状态：拖动取消本次点击，结束后仍阻止延迟 Button 回调，下一次实际按下立即恢复点击；拖动按固定窗口坐标计算，最多提交一次翻日。首页仅在导航根页且场景活跃时接受翻日，离开时取消未完成手势，避免返回手势污染日期。
- 新增 6 项手势回归；首轮发现状态对象释放时崩溃，修复释放隔离后最终 45 项相关测试全部通过（`/private/tmp/butler-day-gesture-tests-final.log`），Release 构建通过（`/private/tmp/butler-day-gesture-device-final.log`）。模拟器经无障碍动作选择明天、正常点击任务再点返回，日期保持明天。实际双向触控与详情侧滑返回尚待手机确认，不能用无障碍动作代替手势验收。
- 最终手势修正版已成功更新安装到 iPhone 14 Pro（安装记录 `7D96031C-35FF-4DA4-9CDC-E1EDA20639CA`）；自动启动因手机锁屏被拒绝，已请用户解锁打开并复验。新增本地事件日志只记翻页方向、点击是否被抑制，不记录任务名称或内容。尚未提交推送或启动云构建。
- 真机复验通过：用户在安装最终手势修正版后明确确认“两项都正常了”——从任务行向未来滑动不再误进详情；正常轻点进入任务详情后侧滑返回，清单日期保持不变。本次通过依据为用户实际触控反馈，区别于前述仅使用无障碍动作的模拟器验证。


### 2026-09-29 提醒卡片、稳定水晶球、删除与等待优化
- “聊聊这件事”改“其他安排”。首页天气最终按用户选择保留中文天气描述，温度和Apple来源移至天气详情，移除首页来源页脚。
- 删除随滚动切换水晶球/摊开状态的入口行为；触碰直接触发UIKit触觉，录音时允许haptics，按真实状态区分录音就绪/取消边界/交付/失败。
- 任务新增真正删除：管理列表左滑/长按、详情按钮和propose_task_action.delete，共用持久化与停止通知逻辑，预览确认和revision校验；取消仍保留历史。
- 从手机提取仅Butler诊断日志到/private/tmp/butler-latency-20260929.log，发现12秒/17秒样本主要是多轮模型请求，另有1–1.5秒Jev前置和1.4–2.2秒HEAD探测。本地任务工具0.0秒。
- 去除正常请求前HEAD，流式呈现正文与实际步骤，新增首字/凭据耗时诊断；未改变模型或绕过写操作确认。
- 90项相关回归通过，日志/private/tmp/butler-interaction-latency-tests.log；模拟器原生界面验证删除确认弹窗及稳定入口，未执行数据删除。真机触觉与线上提速尚待体验验证。
- 真机Release构建成功（/private/tmp/butler-interaction-latency-device.log），已安装到iPhone 14 Pro，bundle com.anvalar.Butler，安装序列2548。尚未提交推送，未触发Xcode Cloud/TestFlight。


### 2026-09-29 原生触碰与语音准备脉冲
- 用户反馈上一版按住仍有停顿，明确要求触碰瞬间震动及收音前持续/加速反馈。本轮覆盖此前“仅离散事件”的准备阶段取舍。
- OrbTouchGesture 在 UIKit touchesBegan 直接交付初始事件，替代 SwiftUI DragGesture 首次回调；保留轻点、拖动、松手和取消，位移在窗口坐标计算。
- VoiceHaptics 预备 Core Haptics pattern，先系统即时轻震，再从220ms间隔加速至120ms的温和脉冲；共享音频会话并启用haptics-only。失败或引擎中断降级系统反馈，跳过延迟期间错过的脉冲，避免补播连震。
- LiveDictation 在 engine.start 成功后直接通知收音就绪，停止脉冲并确认，不再等 SwiftUI onChange。松手/拖离/取消/失败/后台均停止，5秒超时中止准备并提示重试；失败后的松手不会误打开对话。
- 34项相关测试通过：/private/tmp/butler-voice-immediate-final-tests.log；模拟器无障碍点击可打开对话。模拟器未验证实际触摸延迟与马达体感，需最终手机复验。
- 真机Release构建成功并已安装iPhone 14 Pro（安装序列2556），日志/private/tmp/butler-voice-immediate-device.log。已请求用户验证接触瞬间/准备脉冲/收音停止三段手感，等待反馈；未提交推送、未触发云构建。


### 2026-09-29 取消后第二次按压无响应
- 用户报告上一版第一次正常，取消后再次按压失效，切换页面暂时恢复。上一版34项状态/几何测试及无障碍入口验证不足以证明连续真机手势正常，撤回“已完全验证”的任何推断。
- 读取手机Butler诊断到/private/tmp/butler-voice-repeat-before.log。日志可见录音启动及触觉pattern不可用，但旧日志缺少取消/结束路径，不能仅据此确定唯一运行时根因。
- 替换裸UIGestureRecognizer手工状态转换，使用系统UILongPressGestureRecognizer零时长识别与原生super生命周期；保留touchesBegan即时反馈。
- 新增VoiceInteractionSession隔离每次按压与收尾。取消清理收尾任务/期限/finishingVoice，旧准备与动画回调不影响新按压；识别收尾3秒超时后释放入口并提示保留的未发送文本，错误提示不再把入口永久禁用。
- 触觉引擎停止/reset时作废播放器并标记需重启，下次触碰先即时轻震再重新准备；不对已停止的播放器重复发stop。新增触摸开始/结束/取消/收尾超时日志，仅状态不记录语音内容。
- 37项相关测试通过（/private/tmp/butler-voice-repeat-tests.log），含50轮会话取消隔离和20轮触觉取消重试状态测试。UIKit真实触摸复位与马达重启仍需本轮真机验证，不把纯状态测试等同真机成功。
- 本轮Release构建成功（/private/tmp/butler-voice-repeat-device.log），已更新iPhone 14 Pro，安装序列2564。已向用户请求同一页面连续3次按住/上滑取消/再按的真机复验，尚未收到结果。未提交推送。


### 2026-09-29 紧急撤回失效的原生长按入口
- 用户实测安装序列2564后按压完全无响应。本轮手机日志/private/tmp/butler-voice-unresponsive.log仅有interaction reset，没有本版touch began；未进入按压处理链路。不能把上一版37项状态测试解释为实际触摸成功。
- 撤回OrbTouchGesture，恢复曾可用的SwiftUI DragGesture(minimumDistance:0)和GestureState结束/取消检测。撤回Core Haptics脉冲引擎，恢复UIKit触碰/就绪/取消等轻震，与麦克风音频生命周期分离。
- 失败实现只存档/private/tmp/butler-withdrawn-voice-20260929，不参与应用编译。保留固定球、会话隔离和超时保护，其他首页/任务/天气/对话改动不回退。
- 用户要求的连续/渐快触觉暂未完成，优先恢复语音入口。最终实际长按、取消后重按仍需真机复验，不提前宣称修复成功。
- 恢复版本36项相关测试通过（/private/tmp/butler-voice-restore-tests.log）；Release构建成功（/private/tmp/butler-voice-restore-device.log），已安装iPhone 14 Pro，安装序列2572。已请求同页面取消后再次收音复验，结果待确认；未提交推送。

### 2026-09-29 连续触感独立试用页
- 用户否定“触碰轻震→停顿→就绪再震”，同意先在独立界面验证新交互，再决定接入正式水晶球。
- 设置新增“交互试用 → 按住说话 · 连续触感”，全屏覆盖正式入口；独立 LiveDictation，仅显示文字，不发送消息或改库存。正式 OrbDock/VoiceHaptics 本轮未改。
- ContinuousPressFeedback 使用一段连续事件，触碰起振、真实录音开始回调淡出，无就绪/松手第二次冲击。球本体轻微受压与两侧真实声条；取消区边界选择反馈，取消即时清理。触觉最长0.8秒，权限等待不持续震。
- VoicePressTrial 控制器每次会话隔离，旧启动和收尾回调不能污染新按压；准备5秒、收尾3秒保护，超时保留已识别文字。试用页退出、后台清理麦克风和独立触觉引擎。
- 44项回归通过，包含8项控制器/模拟录音器生命周期测试；/private/tmp/butler-voice-trial-tests.log。Release真机构建成功：/private/tmp/butler-voice-trial-device.log。现有工程并发隔离警告仍存在。
- 模拟器检查设置入口、页面布局、关闭后返回设置；原生工具坐标拖动未产生按压事件，因此不算触摸验证。马达体感、连续三次取消重按及初始收音仍待手机实测，不提前宣称解决体验问题。
- 已直接安装到iPhone 14 Pro，安装序列2580，bundle com.anvalar.Butler。未提交推送、未触发Xcode Cloud/TestFlight，等待独立试用页的真机反馈。

### 2026-09-29 试用页首次起振延迟
- 用户报告试用页按压后仍等太久才震。读取/private/tmp/butler-voice-trial-latency.log，可见4次试用按压至麦克风就绪约0.6秒；旧日志不足以判断触摸至起振真实时延。
- 新试用页使用标准UIControl tracking回调直接接触，不使用自定义手势识别器。控制器首先交付触觉；pattern/player提前在引擎就绪与松手后准备，移除按下时创建开销。
- 单段continuous事件起始强度从0.32改0.60，40ms内柔和过渡到0.40，后续平滑保持；真正收音时淡出，仍无第二下ready/成功震动。增加触摸事件送达与播放器start调用耗时日志，不记录语音正文。
- 新增同步反馈先于录音启动和连续触觉包络无空档测试；正式水晶球未改。真机手感仍待实测，不能把调用耗时解释为马达物理启动时间。
- 46项相关测试通过（/private/tmp/butler-voice-contact-tests.log），Release构建成功（/private/tmp/butler-voice-contact-device.log）。模拟器确认新UIControl试用入口存在；未将无障碍操作当成实际触摸验证。已更新iPhone 14 Pro，安装序列2588，未提交推送或云端构建。

### 2026-09-29 已确认触感接入正式水晶球，短按文字/长按语音
- 用户确认安装序列2588的触感可接受，并要求保证短按输入和长按语音。将验证后的标准UIControl与连续触觉推广至OrbDock，与试用页复用VoicePressInteraction；旧的正式入口双次系统震动不再调用。
- 即时触觉独立于0.3秒长按判断。短按松手只调用当前上下文openChat(.typing)，不启用麦克风；达到阈值后只走语音，空语音、超时、取消不转为文字。明显移动不误作短按，语音整理成功只交付一次。
- 正式水晶球稳定轻压、两侧真实音量，移除旧多段球/条/展开绘制和回调；上滑取消、滑回继续、后台清理、5秒准备与3秒收尾保护复用已测控制器。保留独立试用入口。
- 53项相关回归通过（/private/tmp/butler-orb-dual-input-tests.log），含新增7项短按/长按互斥、发送一次和取消路径测试。Release构建成功（/private/tmp/butler-orb-dual-input-device.log）。模拟器通过无障碍入口打开文字对话，截图可见输入框插入光标；模拟器连接硬件键盘，不据此宣称软键盘或真实手指长按已验收。
- 已直接更新iPhone 14 Pro，安装序列2596，bundle com.anvalar.Butler。正式入口待用户真机双操作确认；未提交推送，未触发云端构建。

### 2026-09-29 等待回复时保持悬浮输入区
- 根据用户截图，移除输入区系统safeAreaBar的整块背景与分隔，改透明safeAreaInset保留内容避让，并关闭底部scroll edge遮罩。输入框与两侧按钮继续各自悬浮，页面背景连续。
- 去除“管家正在回答，你可以先写下一条。”，空输入统一为“和管家说…”，不再等待时改成“可以先写下一条…”。保留对话流中的处理状态、停止按钮与必要的语音/错误提示。
- 现有输入与滚动回归19项通过（/private/tmp/butler-floating-composer-tests.log），Release构建成功（/private/tmp/butler-floating-composer-device.log）。模拟器检查了普通状态的背景连续性；未登录真实模型，因此未宣称模拟器复现了真实生成中的截图状态。
- 已更新iPhone 14 Pro，安装序列2604。未提交推送或触发云端构建。

### 2026-09-29 恢复被误删的液态玻璃视觉
- 用户指出此前授权修复的是震动，未要求移除液态玻璃和流动感。此前将触感集成与视觉简化捆绑属于范围错误，本轮撤回视觉简化。
- 从原OrbDock绘制实现恢复液态玻璃表面、内部流光/折射、按压展开、真实声条和与主玻璃连成一体的红色取消区；恢复松手收回。球的位置保持稳定，不恢复先前取消的滚动掉落摊开，也不引入圆形进度。
- 绘制层不接触摸且不触发额外震动，继续使用用户已确认的标准UIControl与预热连续触感；短按文字/长按语音及会话隔离不改。回弹完成以视觉会话ID隔离，防止旧回弹影响新按压。聊天输入区透明悬浮修正保留。
- 60项相关回归通过（/private/tmp/butler-liquid-restore-tests.log），覆盖玻璃轮廓、语音控制器、输入和滚动；马达与恢复动画组合的实际体感仍以手机为准。
- Release构建成功（/private/tmp/butler-liquid-restore-device.log），模拟器检查了恢复后的静止玻璃水晶球与独立可访问入口。已更新iPhone 14 Pro，安装序列2612；未提交推送或触发云端构建。

### 2026-09-29 语音提示与自定义转写服务
- 水晶球空录音提示改为“松开发送，上滑取消”。保留已恢复的液态玻璃、连续触觉、短按文字/长按语音及取消隔离。
- 管家设置新增语音识别页，默认苹果框架；自定义 HTTPS Base URL、模型名、API Key 接入 OpenAI 兼容音频转写。凭据绑定地址并保存系统钥匙串，不参与备份或模型上下文。更换地址需重新输入密钥。
- 自定义模式本机录制 m4a，正常结束才上传，取消不上传；等待转写可取消。限制2分钟，网络40秒/整体收尾45秒保护；苹果仍3秒。旧请求取消/迟到不影响下一轮，失败不发空或部分文本，不静默回退服务。
- 用户指定 AiHubMix。核对官方快速开始、STT与Create Transcription文档：支持 https://aihubmix.com/v1/audio/transcriptions、multipart m4a和JSON text；配置示例记录于 docs/SPEECH_RECOGNITION.md。未使用真实Key，实际账户可用性、识别效果及时延待用户配置验证；当前非实时WebSocket转写。
- 57项相关测试通过（/private/tmp/butler-custom-speech-final-tests.log），覆盖凭据/请求/取消/错误/重定向及交互回归；模拟器确认默认苹果和自定义配置界面。Release构建通过（/private/tmp/butler-custom-speech-device.log），现有工程并发警告未在本次扩大处理。
- 已安装到iPhone 14 Pro，安装序列2620；未提交推送，未触发Xcode Cloud/TestFlight。

### 2026-09-29 AiHubMix 鉴权排查与实时语音
- 手机配置为备用域名 https://api.inferera.com（缺少 /v1）及 gpt-live-transcribe。旧实现错误地请求文件转写路径，又将401/403统一显示为密钥错误。用户明确选择接通实时模型。
- 接入 WebSocket：握手包含 intent/model/Bearer，PCM16/24k/mono、languages zh/en、turn_detection null；会话确认后顺序发送，增量显示，松手commit后最终文字替换并仅发送一次。取消、后台和错误隔离会话。设置明确实时音频已上传部分不可撤回。
- 已知AiHubMix主机自动补 /v1，原主机兼容旧凭据绑定，不跨主机复用。新增安全错误分类与无音频连接检查，不回显服务原文或密钥后缀。
- 首次PCM转换测试发现对象释放崩溃；转换器和网络对象明确nonisolated deinit后36项测试通过（/private/tmp/butler-realtime-tests-fixed.log）。Release构建通过（/private/tmp/butler-realtime-release.log）；仍有工程既存及AVFoundation同步回调的Swift并发警告。
- 手机使用原有钥匙串密钥，实时鉴权及会话配置成功；发送2.09秒本地合成测试句，收到10次文字更新，最终匹配测试句（/private/tmp/butler-speech-sample-result.log）。不导出密钥、不采集用户录音、不发送管家消息。诊断入口仅DEBUG显式启动参数有效。
- 模拟器确认实时模型说明与连接检查入口。已装回Release版至iPhone 14 Pro，安装序列2644；原配置无需重填。实际麦克风与长按/取消体感仍需用户实测。未提交推送或云端构建。

### 2026-09-29 “其他安排”属于整张管家提醒
- 用户指出提醒可能包含多件事情，入口不能绑定某个物品。定位到原回调把 brief.target.scope 直接作为会话归属，误将快捷操作目标等同提醒主题。
- 新增 brief 会话作用域，保存点击时完整提醒正文、日期及快捷操作信息；同日相同内容复用独立历史，提醒更新不篡改已有会话。稳定SHA256路径和scope.json沿用会话持久化/备份，既有物品与任务历史不猜测迁移。
- “其他安排”传递整张可见卡片而非target；没有主要对象时也可打开。聊天标题为“关于这条管家提醒”，顶部保留提醒原文，引导讨论其中任意一件或整体安排。
- 模型上下文明确整张卡片是讨论对象，快捷按钮目标不作为默认指代；修改前查最新数据，多对象歧义先确认。关闭此会话的离线自动新建提醒兜底，防止把调整已有多件安排误解析为新任务。
- 55项相关测试通过（/private/tmp/butler-brief-scope-tests.log），覆盖多主题上下文、旧会话隔离、相同提醒复用、新提醒不覆盖、重启恢复及无对象提醒。模拟器实际点击核对标题、原文及入口提示。
- 最终Release构建通过（/private/tmp/butler-brief-scope-final-release.log），已安装iPhone 14 Pro，安装序列2652。未提交推送或触发云端构建；真实模型对多件安排的回答效果仍待用户对话体验。

### 2026-09-29 本轮 TestFlight 发布准备
- 用户明确要求提交推送并通过 TestFlight 发布。本机与远端 main 基线一致；保留单 main 分支，手动触发 Xcode Cloud，不恢复提交自动构建。
- 汇总本轮日程/通用物品、天气、整张提醒上下文、输入与连续触觉、自定义及实时语音改动；更新 TestFlight 测试说明和 README。
- 发布前全量测试：348项，1项既有 SwiftData 旧磁盘结构升级测试仍显式跳过，0失败（/private/tmp/butler-release-all-tests.log）。最新 Release 构建已通过；git diff --check及凭据扫描通过。
- 已核对 Main · TestFlight 的 Test 必须通过、Archive上传，以及内部和外部两个 test 组的自动分发配置。实际云端结果与测试可用状态以本次构建页面为准。

### 2026-09-29 云端区域差异修复
- 构建25使用 f58fd47，归档编译/签名导出通过，测试被同一用例的两条时间断言拦截，未运行内外部测试分发。
- 根因：clockTime 跟随区域的12小时制却省略AM/PM，美国环境把15:00/21:00显示为03:00/09:00。本机指定英文、美国区域精确复现；改为 en_US_POSIX + HH:mm，继续使用当前本地时区。
- 同时修正提醒工具测试的输入时间格式，直接生成未来完整日期，移除跨午夜跳过断言。美国区域全量348项，1项既有跳过，0失败（/private/tmp/butler-release-us-final-tests.log）。测试门槛保留，修复后重新手动构建。

### 2026-09-29 TestFlight 1.0（26）
- 构建26使用 main 的85f14df，云端Test/Archive成功，内部测试分发成功。外部短暂进入Pending Beta Review后自动通过，版本详情已核对内外部两个test组；中文测试说明保留。
- 发布记录见docs/XCODE_CLOUD.md；全部分发步骤成功，最终时长10分钟、计算用量7分钟。不宣称通知已送达或测试者已安装。结果文档另提交推送，不额外构建。
