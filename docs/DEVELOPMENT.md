# 开发与验证

## 构建

在 macOS 上准备 Xcode Command Line Tools、Go 1.25+ 和构建时的系统 Python 3，运行 `./build.sh`。通过 `-mod=vendor` 构建两个 Go 可执行文件，输出当前主机架构的 `dist/BatteryCare.app`。运行不需要 Python、外部 batt 或独立 HTTP 服务。

脚本对 App 及两个 Go 可执行文件执行 ad-hoc 签名。分发前应使用自己的 Developer ID 重新签名、公证并验证 Gatekeeper。不要把签名证书、私钥、Apple 凭据写入仓库。

App Resources 包含完整的对应源码归档和第三方许可证。发布二进制时保留这些文件，并一并提供当前版本源码、修改说明和许可证。

## 隔离测试

运行 `./test.sh`：

- Go race detector：令牌鉴权、命令白名单、socket 路径、退出及租约超时，使用 mock 适配器。
- Swift：状态/错误模型、实际充电图标、2008 个面板定位案例、阈值/冷却/缺失传感器策略、配置事务及安全启动和退出。

测试不执行管理员授权或真实 SMC 写入，不实际开启 CPU 压力负载。不把 mock 通过描述为所有硬件和 macOS 版本均已验证。历史 Python 启动器及其兼容测试不属于此原生仓库。

## 兼容旧版

可执行文件和显示名称为 BatteryCare；bundle ID `com.local.batterybar`、`BatteryBar/config.json` 和 socket 前缀暂保留，避免强制重置旧配置。不要在运行旧 BatteryBar 的同时启动新构建。助手严格检查父 App 可执行文件名称；如再次重命名必须同步更新 Go 检查与构建脚本，不能放宽身份检查。

应用启动总将 `auto_discharge_enabled` 重置为 false；普通参数保留。旧配置路径属于兼容接口，改动需有迁移和回退方案。运行时配置与备份不能提交 Git。

## 四语言本地化（2.1.0）

英文首页为 `README.md`，其余入口为 `README.zh-CN.md`、`README.zh-TW.md` 与 `README.ja.md`。四个文件顶部互相链接。详细开发、安全和设计文档目前使用简体中文，英文和日文 README 已明确标注。

界面资源位于 `Resources/Localizations/{en,zh-Hans,zh-Hant,ja}.json`，由 `Sources/Localization.swift` 加载。构建时复制到 App 的 `Contents/Resources/Localizations/`，Info.plist 同时声明四种语言和英语开发区域。添加文案时必须补全四个资源中的相同键，并保持 `%@` 占位符一致。

首次启动匹配系统首选语言，支持简繁脚本与台湾、香港、澳门地区识别；无匹配时回落到英语。用户在「设置 → 语言」中的明确选择通过 UserDefaults 的 `BatteryCare.language` 保存，与电源参数 JSON 分离。语言变化只更新展示，不重建引擎、不改变耗电开关、不清空设置草稿。已存储的引擎诊断在展示时翻译，底层工具或系统返回的技术诊断保留原文。

`LocalizationTests` 检查四份文案的键集合、非空值、占位符、语言匹配、保存偏好优先级、复合错误和即时模型切换。测试使用隔离的 UserDefaults suite，不改用户语言偏好，不执行硬件写入。


## 菜单栏位置（2.1.1）

通过公开的 `NSStatusItem.autosaveName` 使用稳定标识 `BatteryCare.MainBattery`，以便 AppKit 保存用户通过 ⌘ 拖动的位置。首次创建时，仅在本 App 的 UserDefaults 域内为 AppKit 的 `NSStatusItem Preferred Position <name>` 约定键写入靠右提示；此键不是正式的位置控制 API，因此只作为尽力提示，系统可能忽略。不读写 Control Center 或其他 App 的位置，不假设原生电池图标可被查询或替换。

设置中的「靠右放置」会仅移除并重建菜单栏项，再应用位置提示；内置引擎、负载、监测计时器和设置草稿不重建。普通启动保留已保存的位置，不反复覆盖手动拖动的结果。精确顺序由 macOS 决定，支持按住 ⌘ 手动拖动。

`BATTERYCARE_APP_OUTPUT=/absolute/path/BatteryCare.app ./build.sh` 可以构建到独立目录，避免覆盖正在运行的 App。更新运行中的应用前请先正常退出；启动后自动耗电仍按安全策略保持关闭。
