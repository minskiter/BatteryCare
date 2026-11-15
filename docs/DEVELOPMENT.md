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
