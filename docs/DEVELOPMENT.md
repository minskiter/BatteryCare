# 开发与验证

## 构建

在 macOS 上准备 Xcode Command Line Tools、Go 1.25+ 和构建时的系统 Python 3，运行 `./build.sh`。通过 `-mod=vendor` 构建两个 Go 可执行文件，输出当前主机架构的 `dist/BatteryCare.app`。运行不需要 Python、外部 batt 或独立 HTTP 服务。

脚本对 App 及两个 Go 可执行文件执行 ad-hoc 签名。分发前应使用自己的 Developer ID 重新签名、公证并验证 Gatekeeper。不要把签名证书、私钥、Apple 凭据写入仓库。

App Resources 包含完整的对应源码归档和第三方许可证。发布二进制时保留这些文件，并一并提供当前版本源码、修改说明和许可证。

## 隔离测试

运行 `./test.sh`：

- Go race detector：令牌鉴权、命令白名单、socket 路径、退出及租约超时，使用 mock 适配器。
- Swift：状态/错误模型、实际充电图标、八种状态环语义、隐藏/减少动态效果的动画门控、配置和偏好迁移、2008 个面板定位案例、阈值/冷却/缺失传感器策略、配置事务及安全启动和退出；新增负载渐进加速、核心/占空比上限、热压力、75°C 停止点、无效读数及工作线程超时/停止/重启测试。

测试不执行管理员授权或真实 SMC 写入，不实际开启 CPU 压力负载。工作线程生命周期测试注入休眠 mock 批次，纯策略测试覆盖不同核心数和热状态。不把 mock 通过描述为所有硬件和 macOS 版本均已验证。历史 Python 启动器及其兼容测试不属于此原生仓库。

## 兼容旧版

2.2 起可执行文件、显示名称和登录项均为 BatteryCare，bundle ID 为 `com.local.batterycare`，配置路径为 `BatteryCare/config.json`。优先读取新版有效配置，缺失或无效时导入旧 `BatteryBar/config.json`，再回退旧 Python 服务配置；导入时原文件不动、新文件原子写入且自动耗电关闭。仅迁移旧偏好域中尚未在新版设置过的语言和菜单位置。socket 内部前缀仍保留旧值，并非应用名称。不要在运行旧 BatteryBar 的同时启动新构建。助手严格检查父 App 可执行文件名称；如再次重命名必须同步更新 Go 检查与构建脚本，不能放宽身份检查。

应用启动总将 `auto_discharge_enabled` 重置为 false；普通参数保留。旧配置路径仅作兼容读取，原文件保留以便回退。升级前先在旧应用取消登录启动，再退出、替换并注册新版；不同 bundle ID 的登录项不会由新版自动注销。运行时配置与备份不能提交 Git。

## 四语言本地化（2.1.0）

英文首页为 `README.md`，其余入口为 `README.zh-CN.md`、`README.zh-TW.md` 与 `README.ja.md`。四个文件顶部互相链接。详细开发、安全和设计文档目前使用简体中文，英文和日文 README 已明确标注。

界面资源位于 `Resources/Localizations/{en,zh-Hans,zh-Hant,ja}.json`，由 `Sources/Localization.swift` 加载。构建时复制到 App 的 `Contents/Resources/Localizations/`，Info.plist 同时声明四种语言和英语开发区域。添加文案时必须补全四个资源中的相同键，并保持 `%@` 占位符一致。

首次启动匹配系统首选语言，支持简繁脚本与台湾、香港、澳门地区识别；无匹配时回落到英语。用户在「设置 → 语言」中的明确选择通过 UserDefaults 的 `BatteryCare.language` 保存，与电源参数 JSON 分离。语言变化只更新展示，不重建引擎、不改变耗电开关、不清空设置草稿。已存储的引擎诊断在展示时翻译，底层工具或系统返回的技术诊断保留原文。

`LocalizationTests` 检查四份文案的键集合、非空值、占位符、语言匹配、保存偏好优先级、复合错误和即时模型切换。测试使用隔离的 UserDefaults suite，不改用户语言偏好，不执行硬件写入。


## 菜单栏位置（2.1.1）

通过公开的 `NSStatusItem.autosaveName` 使用稳定标识 `BatteryCare.MainBattery`，以便 AppKit 保存用户通过 ⌘ 拖动的位置。首次创建时，仅在本 App 的 UserDefaults 域内为 AppKit 的 `NSStatusItem Preferred Position <name>` 约定键写入靠右提示；此键不是正式的位置控制 API，因此只作为尽力提示，系统可能忽略。不读写 Control Center 或其他 App 的位置，不假设原生电池图标可被查询或替换。

设置中的「靠右放置」会仅移除并重建菜单栏项，再应用位置提示；内置引擎、负载、监测计时器和设置草稿不重建。普通启动保留已保存的位置，不反复覆盖手动拖动的结果。精确顺序由 macOS 决定，支持按住 ⌘ 手动拖动。

`BATTERYCARE_APP_OUTPUT=/absolute/path/BatteryCare.app ./build.sh` 可以构建到独立目录，避免覆盖正在运行的 App。更新运行中的应用前请先正常退出；启动后自动耗电仍按安全策略保持关闭。

## BatteryCare 2.2 发布与登录项

构建版本为 2.2.0 / 8。安装到最终路径后可运行 `BatteryCare.app/Contents/MacOS/BatteryCare --login-item enable|disable|status` 管理**当前包**的登录项；该命令不启动监测、硬件授权或耗电循环。旧身份的注销应在替换旧包之前完成；不要重置整个 macOS 登录项数据库。

状态环使用 macOS 13 支持的 `TimelineView` 和基本 SwiftUI 图形，不依赖较新系统的 SF Symbol 特效。面板隐藏时不挂载 timeline，静态状态和“减少动态效果”也不启动 timeline。实际充电状态优先于陈旧的负载标记。动画不写控制状态、不伪造电量，不用于驱动耗电。

## 2.3 电量统计

`BatteryHistoryStore` 是独立 actor，SQLite3 连接只在此 actor 使用。`BatteryModel.refresh()` 复用成功的快照，最多每分钟插入一行，不额外触发传感器、授权或耗电。测试模型 `poll:false` 不创建历史库。历史 IO 错误单独展示，不改变电源状态。`BatteryHistoryAnalysis` 为纯聚合与预测策略，`HistoryPanel` 使用 macOS 13 的 Swift Charts。构建和测试链接系统 `libsqlite3`。

采样会话 ID 在进程重启、时钟回退、系统睡眠/唤醒通知和快照失败时变更；一分钟节流期间也识别无效电量及供电状态切换，避免跨空档累计。只累计两端均明确使用电池、未充电、同会话、正时间差不超过 180 秒、有效且不增加的百分比变化；统计时段边界按间隔占比裁剪。速度需累计 900 秒且下降至少 2 个百分点。曲线保留端点、局部极值及段标识并限制到 800 点；健康曲线使用 UTC 每日均值。

预测最多使用 180 天每日健康度，需至少 14 日且跨度 28 天，累计下降至少 2 个百分点，无大于 7 天的日级空档或单日上升 3 点以上；整体回归 R²≥0.7，完整与两半段下降速度均超过 0.005 点/日、最大最小速率之比≤3。用三个速率的极值、当前整数健康度 ±1 点情景估计首次整数 79%，区间超过 5 年则不预测。其阈值是保守的软件启发式，不是已验证的电化学模型；情景区间不是置信区间。循环计数回退后不混用之前的健康数据。

`HistoryTests` 使用临时数据库、合成日期和模拟快照，覆盖节流、聚合、充电排除、窗口边界、缺失/重启/睡眠、曲线限点、平稳与失效趋势、权限、CSV、循环回退、保留期和清空；不读取真实历史或控制硬件。
