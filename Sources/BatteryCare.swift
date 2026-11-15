// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import ServiceManagement

struct Config: Codable, Equatable {
    var auto_discharge_enabled: Bool
    var low_battery_threshold: Int
    var high_battery_threshold: Int
    var temp_limit: Double
    var cool_down_sleep: Int
    var loop_interval: Int
}
struct Snapshot: Codable {
    struct Service: Codable { var running: Bool; var last_update: String?; var last_error: String? }
    struct Battery: Codable { var percentage: Int?; var charging_state: String?; var power_source: String?; var is_charging: Bool?; var is_plugged_in: Bool?; var cycle_count: Int?; var health_percentage: Int? }
    struct Temperature: Codable { var cpu_celsius: Double?; var limit_celsius: Double }
    struct Discharge: Codable { var enabled: Bool; var cycle_active: Bool; var cpu_load_active: Bool; var caffeinate_active: Bool }
    var service: Service
    var battery: Battery
    var temperature: Temperature
    var auto_discharge: Discharge
    var config: Config
}

enum BatteryIcon {
    static func symbol(percentage: Int?, isCharging: Bool) -> String {
        if isCharging { return "battery.100percent.bolt" }
        switch percentage ?? 0 {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

@MainActor final class BatteryModel: ObservableObject {
    @Published var language = L10n.language
    func setLanguage(_ value: AppLanguage, persist: Bool = true) {
        L10n.setLanguage(value, persist: persist)
        language = value
        onUpdate?()
    }
    @Published var status: Snapshot?
    @Published var connected = false
    @Published var busy = false
    @Published var message: String?
    @Published var lastSync: Date?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var serviceInfo = "内置服务启动中…"
    private let engine: IntegratedEngine?
    private let session: URLSession
    private var refreshing = false
    private var timer: Timer?
    var onUpdate: (() -> Void)?
    let base = URL(string: "http://127.0.0.1:8765")!
    var enabled: Bool { connected && status?.config.auto_discharge_enabled == true }
    var batteryLabel: String { status?.battery.percentage.map { "\($0)%" } ?? "—" }
    var isCharging: Bool { connected && status?.battery.is_charging == true }
    var batterySymbol: String {
        BatteryIcon.symbol(percentage: connected ? status?.battery.percentage : nil, isCharging: isCharging)
    }
    var chargingDescription: String {
        guard connected, let battery = status?.battery else { return L10n.text("充电状态未知") }
        if battery.is_charging == true { return L10n.text("正在充电") }
        if battery.charging_state == "charged" { return L10n.text("已充满 · 未在充电") }
        if battery.is_charging == false { return L10n.text("未在充电") }
        return L10n.text("充电状态未知")
    }
    var mode: String {
        guard connected, let s = status else { return L10n.text("内置服务启动中") }
        if !s.config.auto_discharge_enabled { return L10n.text("自动耗电已关闭") }
        if s.auto_discharge.cpu_load_active { return L10n.text("正在自动耗电") }
        if s.auto_discharge.cycle_active { return L10n.text("温度保护 · 暂停负载") }
        return L10n.text("已开启 · 等待电量阈值")
    }
    init(session: URLSession = .shared, poll: Bool = true) {
        self.session = session
        engine = poll ? IntegratedEngine() : nil
        guard poll else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        if let engine {
            let encoder = JSONEncoder()
            switch (path, method) {
            case ("api/status", "GET"):
                let status = await engine.snapshot()
                serviceInfo = await engine.info()
                return try encoder.encode(status)
            case ("api/config", "GET"): return try encoder.encode(await engine.getConfig())
            case ("api/config", _):
                let object = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any] ?? [:]
                return try encoder.encode(await engine.setConfig(object))
            case ("api/auto-discharge", _):
                let object = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
                guard let enabled = object?["enabled"] as? Bool else { throw EngineFailure(detail: "缺少 enabled 字段。") }
                return try encoder.encode(await engine.setAuto(enabled))
            default: throw EngineFailure(detail: "内置服务不支持该请求。")
            }
        }
        // Injectable legacy transport is retained only for isolated model tests.
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method; req.httpBody = body; req.timeoutInterval = 8
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw NSError(domain: "BatteryCare", code: 1, userInfo: [NSLocalizedDescriptionKey: detail?["message"] as? String ?? "后台请求失败"])
        }
        return data
    }
    func refresh() async {
        guard !refreshing, !busy else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let next = try JSONDecoder().decode(Snapshot.self, from: await request("api/status"))
            // Ignore a read started before a control write; the write refreshes again.
            guard !busy else { return }
            status = next; connected = true; lastSync = Date()
        } catch { connected = false }
        onUpdate?()
    }
    func toggle(_ value: Bool) {
        guard connected, !busy else { return }
        if value {
            let alert = NSAlert()
            alert.messageText = L10n.text("开启自动耗电？")
            alert.informativeText = L10n.text("达到开始阈值后，后台会禁用适配器并增加 CPU 负载。温度过高时会暂停负载；关闭开关会停止负载并尝试恢复充电。")
            alert.addButton(withTitle: L10n.text("开启")); alert.addButton(withTitle: L10n.text("取消"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        write(path: "api/auto-discharge", data: try! JSONSerialization.data(withJSONObject: ["enabled": value]), method: "POST")
    }
    func save(_ config: Config) {
        guard (1...99).contains(config.low_battery_threshold), config.high_battery_threshold > config.low_battery_threshold,
              config.high_battery_threshold <= 100, (40...100).contains(config.temp_limit),
              (1...3600).contains(config.cool_down_sleep), (5...3600).contains(config.loop_interval) else {
            message = "参数无效：停止阈值必须小于开始阈值；温度 40–100°C，轮询 5–3600 秒。"; return
        }
        // Saving parameters never implicitly changes the discharge switch.
        let fields: [String: Any] = ["low_battery_threshold": config.low_battery_threshold,
            "high_battery_threshold": config.high_battery_threshold, "temp_limit": config.temp_limit,
            "cool_down_sleep": config.cool_down_sleep, "loop_interval": config.loop_interval]
        write(path: "api/config", data: try! JSONSerialization.data(withJSONObject: fields), method: "PATCH")
    }
    private func write(path: String, data: Data, method: String) {
        guard !busy else { return }; busy = true; message = nil
        Task {
            do { _ = try await request(path, method: method, body: data) }
            catch { message = error.localizedDescription }
            busy = false
            // A previously in-flight read must finish before the post-write read.
            while refreshing { try? await Task.sleep(nanoseconds: 20_000_000) }
            await refresh()
        }
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if value && !loginEnabled { message = "请在系统设置 → 通用 → 登录项中允许 BatteryCare。" }
        } catch { message = error.localizedDescription }
    }
    func openNativeBatterySettings() {
        // Use the supported System Settings UI instead of writing undocumented
        // Control Center preference bitmasks or restarting the menu bar process.
        let target = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
        if !NSWorkspace.shared.open(target) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
    func prepareControl() {
        guard let engine, !busy else { return }
        busy = true; message = nil
        Task {
            do {
                try await engine.prepare(migrate: true)
                message = "内置电源控制已就绪；旧服务（如有）已备份停用。自动耗电仍需手动开启。"
            } catch { message = error.localizedDescription }
            busy = false
            while refreshing { try? await Task.sleep(nanoseconds: 20_000_000) }
            await refresh()
        }
    }
    func shutdown() async throws {
        timer?.invalidate(); timer = nil
        do { try await engine?.shutdown() }
        catch {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            throw error
        }
    }

}

struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .popover
        view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07)))
    }
}
struct Metric: View {
    let icon: String; let title: String; let value: String; let hint: String
    var body: some View {
        Card {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
struct BatteryPanel: View {
    @ObservedObject var model: BatteryModel
    var settings: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: model.batterySymbol).font(.system(size: 22)).foregroundStyle(.green)
                    .frame(width: 42, height: 42).background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("BatteryCare").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(model.connected ? .green : .orange).frame(width: 5, height: 5)
                        Text(model.connected ? L10n.text("电池控制中心") : L10n.text("监测启动中")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L10n.text("刷新状态")).disabled(model.busy)
            }
            Card {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("当前电量")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(model.batteryLabel).font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit()
                        Label(powerText, systemImage: model.status?.battery.is_plugged_in == true ? "powerplug.fill" : "battery.50percent")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(.primary.opacity(0.07), lineWidth: 7)
                        Circle().trim(from: 0, to: CGFloat(model.status?.battery.percentage ?? 0) / 100)
                            .stroke(model.enabled ? Color.orange : Color.green, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: model.isCharging ? "bolt.fill" : "leaf.fill")
                            .font(.system(size: 27)).foregroundStyle(model.enabled ? .orange : .green)
                    }.frame(width: 82, height: 82).padding(.trailing, 5)
                }
            }
            Card {
                Toggle(isOn: Binding(get: { model.enabled }, set: { model.toggle($0) })) {
                    Label(L10n.text("自动耗电"), systemImage: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
                }.toggleStyle(.switch).controlSize(.small).disabled(!model.connected || model.busy)
                HStack {
                    Text(model.busy ? L10n.text("正在同步…") : model.mode).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if let c = model.status?.config { Text("\(c.low_battery_threshold)% – \(c.high_battery_threshold)%").font(.system(size: 11, weight: .medium)).monospacedDigit() }
                }
            }
            HStack(spacing: 10) {
                Metric(icon: "thermometer.medium", title: L10n.text("CPU 温度"), value: model.status?.temperature.cpu_celsius.map { String(format: "%.1f°", $0) } ?? "—",
                       hint: model.status.map { L10n.format("temperature.limit", String(Int($0.temperature.limit_celsius))) } ?? L10n.text("等待内置监测"))
                Metric(icon: "heart", title: L10n.text("电池健康"), value: model.status?.battery.health_percentage.map { "\($0)%" } ?? "—",
                       hint: model.status?.battery.cycle_count.map { L10n.format("battery.cycles", String($0)) } ?? L10n.text("暂无循环数据"))
            }
            if let error = model.message ?? model.status?.service.last_error {
                Text(L10n.text(error)).font(.system(size: 11)).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).lineLimit(4)
            }
            if !model.connected {
                Button(L10n.text("重试内置监测")) { Task { await model.refresh() } }.buttonStyle(.borderless)
                Text(L10n.text("无需安装外置服务；打开 App 即开始监测。")).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.6)
            HStack {
                Button(action: settings) { Label(L10n.text("设置"), systemImage: "slider.horizontal.3") }.buttonStyle(.borderless)
                Spacer()
                Text(model.connected ? L10n.text("每 5 秒同步") : L10n.text("离线 · 数据可能已过期")).font(.system(size: 10)).foregroundStyle(.tertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help(L10n.text("退出 App，并停止耗电、恢复适配器"))
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 360).background(Glass()).preferredColorScheme(nil).environment(\.locale, Locale(identifier: model.language.rawValue))
    }
    var powerText: String {
        guard let b = model.status?.battery else { return L10n.text("等待电池数据") }
        if b.is_charging == true { return L10n.text("正在充电") }
        if b.is_plugged_in == true { return b.charging_state == "charged" ? L10n.text("电量已充满 · 外接电源") : L10n.text("已连接外接电源") }
        return L10n.text("使用电池电源")
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: BatteryModel
    @State private var draft: Config?
    @State private var dirty = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("BatteryCare 设置")).font(.title3.bold())
                    Text(L10n.text("原生菜单栏 · App 内置控制引擎")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Card {
                Picker(L10n.text("language.title"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text(L10n.text("language.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                Toggle(L10n.text("登录时打开菜单栏 App"), isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text(L10n.text("登录时启动 App 和内置监测；自动耗电不会随启动自动开启。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Label(L10n.text("系统原生电池图标"), systemImage: "menubar.rectangle")
                    Spacer()
                    Button(L10n.text("隐藏／显示…")) { model.openNativeBatterySettings() }
                        .help(L10n.text("打开系统菜单栏设置，由你选择是否显示原生电池图标"))
                }
                Text(L10n.text("在系统设置 → 菜单栏中，取消勾选「电池」即可隐藏原生图标。旧版 macOS 位于控制中心 → 电池 → 在菜单栏中显示。不影响 BatteryCare 或实际充电。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if draft != nil {
                Card {
                    Text(L10n.text("运行参数")).font(.headline)
                    numberRow(L10n.text("停止耗电阈值"), key: \.low_battery_threshold, unit: "%")
                    numberRow(L10n.text("开始耗电阈值"), key: \.high_battery_threshold, unit: "%")
                    HStack {
                        Text(L10n.text("CPU 温度上限")); Spacer()
                        TextField(L10n.text("温度"), value: Binding(get: { draft?.temp_limit ?? 80 }, set: { draft?.temp_limit = $0; dirty = true }), format: .number)
                            .frame(width: 75).multilineTextAlignment(.trailing)
                        Text("°C").foregroundStyle(.secondary).frame(width: 25)
                    }
                    numberRow(L10n.text("过热冷却等待"), key: \.cool_down_sleep, unit: L10n.text("秒"))
                    numberRow(L10n.text("控制轮询间隔"), key: \.loop_interval, unit: L10n.text("秒"))
                    Divider()
                    Text(L10n.text("达到高阈值开始耗电，降至低阈值停止。增加 CPU 负载会消耗电量并产生热量；仅在确有需要时开启。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L10n.text("重新载入")) { draft = model.status?.config; dirty = false }
                        Spacer()
                        Button(L10n.text("保存参数")) { if let draft { model.save(draft) } }
                            .buttonStyle(.borderedProminent).tint(.green).disabled(!dirty || model.busy || !model.connected)
                    }
                }
            } else {
                Text(L10n.text("内置监测启动后即可编辑参数。")).foregroundStyle(.secondary)
            }
            if let message = model.message ?? model.status?.service.last_error {
                Text(L10n.text(message)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("迁移／授权电源控制…")) { model.prepareControl() }.disabled(model.busy)

                Spacer()
                Text("v2.1.0").font(.caption).foregroundStyle(.tertiary)
            }
            Text(L10n.text(model.serviceInfo)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("服务现已集成在 App 内，无需 Python 或独立 LaunchDaemon。关闭设置窗口不会退出；退出 App 会停止负载并恢复适配器。")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.environment(\.locale, Locale(identifier: model.language.rawValue)).textFieldStyle(.roundedBorder).padding(24).frame(width: 470).background(Glass())
            .onAppear { draft = model.status?.config }
            .onChange(of: model.status?.config) { next in if next == draft { dirty = false }; if !dirty { draft = next } }
    }
    func numberRow(_ title: String, key: WritableKeyPath<Config, Int>, unit: String) -> some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: Binding(get: { draft?[keyPath: key] ?? 0 }, set: { draft?[keyPath: key] = $0; dirty = true }), format: .number)
                .frame(width: 75).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 25)
        }
    }
}

// All coordinates here are AppKit screen points (bottom-left origin), not pixels.
// Keeping placement pure makes negative-origin / stacked-display layouts testable.
enum StatusPanelPlacement {
    static func frame(anchor: NSRect, visibleFrame: NSRect, contentSize: NSSize) -> NSRect {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(contentSize.width, safe.width)
        let height = min(contentSize.height, safe.height)
        let x = min(max(anchor.midX - width / 2, safe.minX), safe.maxX - width)
        let y = min(max(anchor.minY - 6 - height, safe.minY), safe.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BatteryModel()
    var statusItem: NSStatusItem!
    var panel: StatusPanel!
    var panelHost: NSHostingView<BatteryPanel>!
    var panelScroll: NSScrollView!
    var settingsWindow: NSWindow?
    var globalMonitor: Any?
    var localMonitor: Any?
    var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.BatteryCare").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            duplicate.activate(options: .activateIgnoringOtherApps); NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(clicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        configurePanel()
        model.onUpdate = { [weak self] in
            self?.updateStatus()
            // Let SwiftUI apply a status/error change before measuring its new height.
            DispatchQueue.main.async { [weak self] in
                if self?.panel.isVisible == true { self?.positionPanel() }
            }
        }
        updateStatus()
        if CommandLine.arguments.contains("--migrate-legacy") { model.prepareControl() }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showPopover() }
        }
    }
    func configurePanel() {
        panelHost = NSHostingView(rootView: BatteryPanel(model: model) { [weak self] in self?.showSettings() })
        panelHost.setFrameSize(NSSize(width: 360, height: 520))
        panelScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 520))
        panelScroll.drawsBackground = false
        panelScroll.hasVerticalScroller = true; panelScroll.autohidesScrollers = true
        panelScroll.scrollerStyle = .overlay; panelScroll.documentView = panelHost
        panel = StatusPanel(contentRect: panelScroll.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L10n.text("BatteryCare 电池控制")
        panel.contentView = panelScroll
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panelScroll.wantsLayer = true; panelScroll.layer?.cornerRadius = 20
        panelScroll.layer?.masksToBounds = true
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                if self.statusAnchor()?.contains(NSEvent.mouseLocation) != true { self.hidePanel() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.hidePanel(); return nil }
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.statusItem.button?.window {
                self.hidePanel()
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.panel.isVisible == true { self?.positionPanel() } }
        }
    }
    func statusAnchor() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    func positionPanel() {
        guard let anchor = statusAnchor(), let screen = NSScreen.screens.first(where: {
            $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY))
        }) ?? statusItem.button?.window?.screen ?? NSScreen.main else { return }
        panelHost.layoutSubtreeIfNeeded()
        let natural = NSSize(width: 360, height: max(1, ceil(panelHost.fittingSize.height)))
        panelHost.setFrameSize(natural)
        let frame = StatusPanelPlacement.frame(anchor: anchor, visibleFrame: screen.visibleFrame, contentSize: natural)
        panel.setFrame(frame, display: panel.isVisible)
        panelScroll.contentView.scroll(to: .zero)
        if CommandLine.arguments.contains("--debug-placement") {
            let log = "anchor=\(NSStringFromRect(anchor)) visible=\(NSStringFromRect(screen.visibleFrame)) panel=\(NSStringFromRect(frame)) content=\(NSStringFromSize(natural)) contained=\(screen.visibleFrame.contains(frame))\n"
            NSLog("%@", log)
            if let data = log.data(using: .utf8) {
                try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BatteryCare-placement.txt"))
            }
        }
    }
    func updateStatus() {
        panel?.title = L10n.text("BatteryCare 电池控制")
        settingsWindow?.title = L10n.text("BatteryCare 设置")
        let image = NSImage(systemSymbolName: model.batterySymbol, accessibilityDescription: "BatteryCare · " + model.chargingDescription)
        image?.isTemplate = true; statusItem?.button?.image = image
        statusItem?.button?.title = " " + (model.connected ? model.batteryLabel : "—")
        statusItem?.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem?.button?.toolTip = "BatteryCare · \(model.chargingDescription)\n\(model.mode)\n" + L10n.text("panel.actions")
    }
    @objc func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if panel.isVisible { hidePanel() } else { showPopover() }
    }
    func hidePanel() { panel.orderOut(nil); statusItem.button?.highlight(false) }
    func showPopover() {
        // Use an explicitly positioned panel rather than NSPopover's automatic
        // preferred-edge placement, which can move tall content above the screen.
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        Task { await model.refresh() }
    }
    func showMenu() {
        hidePanel()
        let menu = NSMenu()
        let toggle = NSMenuItem(title: L10n.text("自动耗电"), action: #selector(quickToggle), keyEquivalent: "")
        toggle.target = self; toggle.state = model.enabled ? .on : .off; toggle.isEnabled = model.connected && !model.busy
        menu.autoenablesItems = false; menu.addItem(toggle); menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("设置…"), action: #selector(openSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let quit = NSMenuItem(title: L10n.text("退出 App 并停止耗电"), action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc func quickToggle() { model.toggle(!model.enabled) }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func openSettings() { showSettings() }
    func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            let height = min(840, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
            let controller = NSHostingController(rootView: ScrollView {
                SettingsPanel(model: model)
            }.frame(width: 470, height: height))
            let window = NSWindow(contentViewController: controller)
            window.title = L10n.text("BatteryCare 设置"); window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true; window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            do {
                try await model.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.text("耗电负载已停止，但无法确认适配器已恢复")
                alert.informativeText = L10n.text(error.localizedDescription) + "\n" + L10n.text("quit.recovery")
                alert.addButton(withTitle: L10n.text("返回 App")); alert.addButton(withTitle: L10n.text("仍退出"))
                NSApp.activate(ignoringOtherApps: true)
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPopover(); return true }
}
#if !BATTERYBAR_TESTING
@main struct BatteryCareMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
