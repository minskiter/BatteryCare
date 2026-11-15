// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import IOKit.pwr_mgt

extension Config {
    var isValid: Bool {
        (1...99).contains(low_battery_threshold) && high_battery_threshold > low_battery_threshold && high_battery_threshold <= 100 &&
        (40...100).contains(temp_limit) && (1...3600).contains(cool_down_sleep) && (5...3600).contains(loop_interval)
    }
    static var safeDefault: Config { Config(auto_discharge_enabled: false, low_battery_threshold: 10, high_battery_threshold: 20, temp_limit: 80, cool_down_sleep: 30, loop_interval: 60) }
}
struct EngineFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
struct CommandResult { let status: Int32; let output: Data; var text: String { String(data: output, encoding: .utf8) ?? "" } }
enum EngineCommand {
    static func run(_ path: String, _ args: [String], timeout: Double = 15) throws -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let cancel = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: cancel)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); cancel.cancel()
        return CommandResult(status: process.terminationStatus, output: data)
    }
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// Privilege is confined to the bundled hardware helper, not the UI, temperature
// reader or load loop. The helper accepts a small authenticated command set.
final class HardwareLease: @unchecked Sendable {
    private let executable: String
    private let socket: String
    private let token = UUID().uuidString + UUID().uuidString
    private var heartbeat: Task<Void, Never>?
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    init(bundle: Bundle = .main) {
        executable = bundle.bundleURL.appendingPathComponent("Contents/Helpers/BatteryHardware").path
        socket = "/var/run/batterybar.\(getuid()).\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).sock"
    }
    private func setReady(_ value: Bool) { lock.lock(); ready = value; lock.unlock() }
    func call(_ action: String) throws -> [String: Any] {
        let result = try EngineCommand.run(executable, ["--client", "--socket", socket, "--token", token, "--action", action], timeout: 6)
        guard result.status == 0, let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any], object["ok"] as? Bool == true else {
            throw EngineFailure(detail: "电源控制助手：" + result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return object
    }
    func authorize(migrate: Bool) throws {
        if isReady, (try? call("ping")) != nil { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw EngineFailure(detail: "App 内缺少 BatteryHardware，请重新构建。") }
        var args = [executable, "--serve", "--socket", socket, "--token", token,
                    "--parent", String(ProcessInfo.processInfo.processIdentifier), "--uid", String(getuid())]
        if migrate { args.append("--migrate-legacy") }
        // Every argument is quoted; no user-supplied shell fragments are accepted.
        let command = args.map(EngineCommand.shellQuote).joined(separator: " ") + " > /dev/null 2>&1 &"
        let sudo = try EngineCommand.run("/usr/bin/sudo", ["-n", "/bin/sh", "-c", command], timeout: 5)
        if sudo.status != 0 {
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let auth = try EngineCommand.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 180)
            guard auth.status == 0 else { throw EngineFailure(detail: "未获得管理员授权，未开启耗电。" + auth.text) }
        }
        var success = false
        for _ in 0..<150 {
            if (try? call("ping")) != nil { success = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard success else { throw EngineFailure(detail: "内置电源助手未能启动。请确认硬件支持适配器控制，或重试迁移旧服务。") }
        setReady(true)
        heartbeat?.cancel()
        heartbeat = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if (try? self.call("ping")) == nil { self.setReady(false); return }
            }
        }
    }
    func shutdown() throws {
        guard isReady else { return }
        _ = try call("shutdown")
        heartbeat?.cancel(); heartbeat = nil; setReady(false)
    }
}

// A single bounded CPU worker. Its lease expires if sensor refreshes stall.
final class BoundedLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var expires = Date.distantPast
    private var result = 0.0
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active && Date() < expires }
    func renew() {
        lock.lock(); expires = Date().addingTimeInterval(12)
        if active { lock.unlock(); return }
        active = true; generation += 1; let ticket = generation; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                self.lock.lock()
                let allowed = self.active && self.generation == ticket && Date() < self.expires
                if !allowed && self.generation == ticket { self.active = false }
                self.lock.unlock()
                if !allowed { return }
                var value = 0.0
                for i in 1...40_000 { value += sqrt(Double(i)) }
                self.lock.lock(); self.result = value; self.lock.unlock()
            }
        }
    }
    func stop() { lock.lock(); active = false; generation += 1; expires = .distantPast; lock.unlock() }
}

enum DischargeDecision: Equatable { case idle, discharge, cooldown, unavailable }
enum DischargePolicy {
    static func decide(config: Config, percentage: Int?, temperature: Double?, wasActive: Bool, cooling: Bool) -> DischargeDecision {
        guard config.auto_discharge_enabled else { return .idle }
        guard let p = percentage, let temp = temperature else { return .unavailable }
        if p <= config.low_battery_threshold { return .idle }
        guard wasActive || p >= config.high_battery_threshold else { return .idle }
        if temp >= config.temp_limit || cooling { return .cooldown }
        return .discharge
    }
}

actor IntegratedEngine {
    private var config: Config
    private let configURL: URL
    private let hardware: HardwareLease
    private let load = BoundedLoad()
    private var cycleActive = false
    private var adapterEnabled: Bool? = nil
    private var coolingUntil = Date.distantPast
    private var nextCycleCheck = Date.distantPast
    private var assertion: IOPMAssertionID = 0
    private var serviceError: String?
    private var lastSnapshot: Snapshot?
    private var cachedHealth: Int?
    private var lastHealthRead = Date.distantPast
    private var running = true
    private let sensorsEnabled: Bool
    static let legacyPlist = "/Library/LaunchDaemons/com.local.battery-service.plist"
    init(configURL: URL? = nil, sensorsEnabled: Bool = true) {
        self.configURL = configURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BatteryBar/config.json")
        self.sensorsEnabled = sensorsEnabled
        hardware = HardwareLease()
        let oldURL = URL(fileURLWithPath: "/Library/Application Support/BatteryService/config.json")
        if let data = try? Data(contentsOf: self.configURL), let saved = try? JSONDecoder().decode(Config.self, from: data) { config = saved }
        else if let data = try? Data(contentsOf: oldURL), let old = try? JSONDecoder().decode(Config.self, from: data) { config = old }
        else { config = .safeDefault }
        if !config.isValid { config = .safeDefault }
        // Never resume CPU stress merely by opening the App or after a crash.
        config.auto_discharge_enabled = false
    }
    func info() -> String {
        if FileManager.default.fileExists(atPath: Self.legacyPlist) { return "内置监测已启动 · 检测到旧服务，需迁移后启用控制" }
        return hardware.isReady ? "内置服务运行中 · 电源控制已授权" : "内置服务运行中 · 首次控制需要管理员授权"
    }
    func prepare(migrate: Bool) throws {
        try hardware.authorize(migrate: migrate)
        stopLoad(); cycleActive = false; config.auto_discharge_enabled = false
        _ = try hardware.call("enable"); adapterEnabled = true; serviceError = nil
        try persist()
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
    func getConfig() -> Config { config }
    func setConfig(_ updates: [String: Any]) throws -> Config {
        let allowed = Set(["low_battery_threshold", "high_battery_threshold", "temp_limit", "cool_down_sleep", "loop_interval"])
        guard Set(updates.keys).isSubset(of: allowed) else { throw EngineFailure(detail: "配置包含未知字段。") }
        var next = config
        if let n = updates["low_battery_threshold"] as? Int { next.low_battery_threshold = n }
        if let n = updates["high_battery_threshold"] as? Int { next.high_battery_threshold = n }
        if let n = updates["temp_limit"] as? Double { next.temp_limit = n }
        if let n = updates["cool_down_sleep"] as? Int { next.cool_down_sleep = n }
        if let n = updates["loop_interval"] as? Int { next.loop_interval = n }
        guard (1...99).contains(next.low_battery_threshold), next.high_battery_threshold > next.low_battery_threshold,
              next.high_battery_threshold <= 100, (40...100).contains(next.temp_limit),
              (1...3600).contains(next.cool_down_sleep), (5...3600).contains(next.loop_interval) else { throw EngineFailure(detail: "运行参数超出安全范围。") }
        let old = config; config = next; nextCycleCheck = .distantPast
        do { try persist() } catch { config = old; throw error }
        return config
    }
    func setAuto(_ enabled: Bool) throws -> Config {
        if enabled {
            try hardware.authorize(migrate: FileManager.default.fileExists(atPath: Self.legacyPlist))
            adapterEnabled = try hardware.call("status")["enabled"] as? Bool; serviceError = nil
        } else {
            stopLoad(); cycleActive = false
            if hardware.isReady { _ = try hardware.call("enable"); adapterEnabled = true }
        }
        config.auto_discharge_enabled = enabled
        nextCycleCheck = .distantPast
        do { try persist() } catch {
            // A failed save must never leave a newly enabled stress cycle running.
            config.auto_discharge_enabled = false; stopLoad(); cycleActive = false
            if hardware.isReady { _ = try? hardware.call("enable"); adapterEnabled = true }
            throw error
        }
        return config
    }
    func snapshot() -> Snapshot {
        let battery: Snapshot.Battery
        var temp: Double?
        if sensorsEnabled {
            battery = readBattery()
            temp = readTemperature()
        } else { battery = Snapshot.Battery(percentage: nil, charging_state: nil, power_source: nil, is_charging: nil, is_plugged_in: nil, cycle_count: nil, health_percentage: nil) }
        if running { control(percentage: battery.percentage, temperature: temp) }
        let result = Snapshot(service: .init(running: running, last_update: ISO8601DateFormatter().string(from: Date()), last_error: serviceError), battery: battery,
            temperature: .init(cpu_celsius: temp, limit_celsius: config.temp_limit),
            auto_discharge: .init(enabled: config.auto_discharge_enabled, cycle_active: cycleActive, cpu_load_active: load.isActive, caffeinate_active: assertion != 0 && load.isActive), config: config)
        lastSnapshot = result
        return result
    }
    private func control(percentage: Int?, temperature: Double?) {
        let decision = DischargePolicy.decide(config: config, percentage: percentage, temperature: temperature, wasActive: cycleActive, cooling: Date() < coolingUntil)
        guard config.auto_discharge_enabled else { stopLoad(); cycleActive = false; return }
        guard hardware.isReady else {
            stopLoad(); cycleActive = false; config.auto_discharge_enabled = false
            serviceError = "电源助手连接已断开，自动耗电已安全停用。"; try? persist(); return
        }
        // Respect the configured cycle interval, but never delay a low-battery,
        // over-temperature, sensor-loss or helper-loss safety stop. Active load
        // still receives a fresh 12-second lease only after every sensor sample.
        let safetyStop = decision == .idle && (percentage ?? 0) <= config.low_battery_threshold || decision == .unavailable || decision == .cooldown
        if Date() < nextCycleCheck && !safetyStop {
            if load.isActive { startLoad() }
            return
        }
        nextCycleCheck = decision == .cooldown ? .distantPast : Date().addingTimeInterval(Double(config.loop_interval))
        do {
            switch decision {
            case .idle, .unavailable:
                stopLoad(); cycleActive = false
                if adapterEnabled != true { _ = try hardware.call("enable"); adapterEnabled = true }
                if decision == .unavailable { serviceError = "电量或 CPU 温度不可用，已暂停耗电并恢复适配器。" }
            case .cooldown:
                stopLoad(); cycleActive = true
                if let temperature, temperature >= config.temp_limit { coolingUntil = Date().addingTimeInterval(Double(config.cool_down_sleep)) }
            case .discharge:
                // Do not start CPU load until the hardware has acknowledged AC cutoff.
                if adapterEnabled != false { _ = try hardware.call("disable"); adapterEnabled = false }
                cycleActive = true; serviceError = nil; startLoad()
            }
        } catch {
            stopLoad(); cycleActive = false; config.auto_discharge_enabled = false
            _ = try? hardware.call("enable"); adapterEnabled = nil
            serviceError = error.localizedDescription; try? persist()
        }
    }
    private func startLoad() {
        load.renew()
        if assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "BatteryCare auto discharge" as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0 }
        }
        if assertion != 0 {
            // Do not keep the Mac awake indefinitely if refreshes stop. The
            // default timeout action turns the assertion off; a fresh safe
            // sensor sample re-arms it together with the CPU worker lease.
            IOPMAssertionSetProperty(assertion, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: 15))
            IOPMAssertionSetProperty(assertion, kIOPMAssertionLevelKey as CFString, NSNumber(value: kIOPMAssertionLevelOn))
        }
    }
    private func stopLoad() {
        load.stop()
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }
    func shutdown() throws {
        stopLoad(); cycleActive = false; config.auto_discharge_enabled = false
        try persist()
        try hardware.shutdown()
        running = false
    }
    private func readBattery() -> Snapshot.Battery {
        var percentage: Int?, cycles: Int?, charging: Bool?, plugged: Bool?, state: String?, source: String?
        if let data = try? EngineCommand.run("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery", "-a"], timeout: 5).output,
           let list = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]], let d = list.first {
            percentage = d["CurrentCapacity"] as? Int; cycles = d["CycleCount"] as? Int
            charging = d["IsCharging"] as? Bool; plugged = d["ExternalConnected"] as? Bool
            state = charging == true ? "charging" : (d["FullyCharged"] as? Bool == true ? "charged" : "discharging")
            source = plugged == true ? "AC Power" : "Battery Power"
        }
        if Date().timeIntervalSince(lastHealthRead) > 300 {
            lastHealthRead = Date()
            if let output = try? EngineCommand.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"], timeout: 15).output,
               let obj = try? JSONSerialization.jsonObject(with: output) { cachedHealth = Self.health(in: obj) ?? cachedHealth }
        }
        return .init(percentage: percentage, charging_state: state, power_source: source, is_charging: charging, is_plugged_in: plugged, cycle_count: cycles, health_percentage: cachedHealth)
    }
    static func health(in value: Any) -> Int? {
        if let d = value as? [String: Any] {
            for (key, value) in d {
                if key.lowercased().contains("maximum") && key.lowercased().contains("capacity"), let text = value as? String,
                   let n = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)), (1...100).contains(n) { return n }
                if let found = health(in: value) { return found }
            }
        }
        if let a = value as? [Any] { for v in a { if let n = health(in: v) { return n } } }
        return nil
    }
    private func readTemperature() -> Double? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/iSMC").path
        guard let result = try? EngineCommand.run(path, ["temp"], timeout: 6), result.status == 0 else { return nil }
        let regex = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*°C"#)
        let values = result.text.split(separator: "\n").filter { $0.contains("CPU") }.flatMap { line -> [Double] in
            let line = String(line)
            return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
                guard let range = Range(match.range(at: 1), in: line) else { return nil }; return Double(line[range])
            }
        }
        return values.max()
    }
}
