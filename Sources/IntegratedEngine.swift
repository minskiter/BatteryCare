// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import IOKit.pwr_mgt

extension Config {
    var isValid: Bool {
        (1...99).contains(low_battery_threshold) && high_battery_threshold > low_battery_threshold && high_battery_threshold <= 100 &&
        (40...100).contains(temp_limit) && (1...3600).contains(cool_down_sleep) && (5...3600).contains(loop_interval)
    }
    static var safeDefault: Config { Config(auto_discharge_enabled: false, low_battery_threshold: 10, high_battery_threshold: 20, temp_limit: 75, cool_down_sleep: 30, loop_interval: 60) }
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

// Policy caps are conservative application budgets, not hardware safety ratings.
struct LoadPlan: Equatable {
    let workers: Int
    let duty: Double
    static let stopped = LoadPlan(workers: 0, duty: 0)
}
enum AdaptiveLoadPolicy {
    static func workerLimit(processors: Int) -> Int { max(1, min(4, processors / 2)) }
    static func temperatureLimit(_ configured: Double) -> Double { min(configured, 75) }
    static func plan(temperature: Double, limit: Double, thermal: ProcessInfo.ThermalState,
                     processors: Int, previous: LoadPlan) -> LoadPlan {
        let ceiling = temperatureLimit(limit)
        guard temperature.isFinite, temperature > 0, temperature < ceiling else { return .stopped }
        let workers: Int
        let maximumDuty: Double
        switch thermal {
        case .nominal:
            workers = workerLimit(processors: processors)
            // Taper over the final 15 degrees instead of hitting the stop limit at full load.
            maximumDuty = 0.15 + 0.70 * min(1, max(0, (ceiling - temperature) / 15))
        case .fair:
            workers = 1; maximumDuty = 0.25
        case .serious, .critical: return .stopped
        @unknown default: return .stopped
        }
        // Increase by at most 0.25 core per sample, but reduce immediately.
        let previousBudget = Double(previous.workers) * previous.duty
        let budget = min(Double(workers) * maximumDuty, previousBudget + 0.25)
        let count = min(workers, max(1, Int(ceil(budget / maximumDuty))))
        return LoadPlan(workers: count, duty: budget / Double(count))
    }
}

// Small, register-only batches: no GPU work, buffers, disk writes or networking.
// Monotonic leases and short slices bound cancellation even if UI sampling stalls.
final class BoundedLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var launched = 0
    private var expires = ContinuousClock.now
    private var plan = LoadPlan.stopped
    private let capacity: Int
    private let leaseDuration: TimeInterval
    private let thermalState: () -> ProcessInfo.ThermalState
    private let batch: (Double) -> Double
    init(workerCapacity: Int = AdaptiveLoadPolicy.workerLimit(processors: ProcessInfo.processInfo.activeProcessorCount),
         leaseDuration: TimeInterval = 12,
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         batch: @escaping (Double) -> Double = BoundedLoad.compute) {
        capacity = max(1, min(4, workerCapacity)); self.leaseDuration = leaseDuration
        self.thermalState = thermalState; self.batch = batch
    }
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active && ContinuousClock.now < expires
    }
    @inline(never) private static func compute(_ seed: Double) -> Double {
        var value = seed
        // The data dependency prevents optimization into a constant or one cached sum.
        for i in 1...2_048 { value = sqrt(value + Double(i)) }
        return value
    }
    func renew(plan next: LoadPlan) {
        guard next.workers > 0, next.duty.isFinite, next.duty > 0 else { stop(); return }
        lock.lock()
        plan = LoadPlan(workers: min(capacity, next.workers), duty: min(0.85, next.duty))
        expires = ContinuousClock.now.advanced(by: .seconds(leaseDuration))
        if !active { active = true; generation += 1; launched = 0 }
        let first = launched
        launched = max(launched, plan.workers)
        let last = launched
        let ticket = generation
        lock.unlock()
        // Allocate additional workers only when the ramp actually needs them.
        for index in first..<last {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var value = Double(index + 1)
                while let self {
                    let start = ProcessInfo.processInfo.systemUptime
                    let thermal = self.thermalState()
                    self.lock.lock()
                    let allowed = self.active && self.generation == ticket && ContinuousClock.now < self.expires
                    let current = self.plan
                    // Fail closed on new/unknown OS thermal states too.
                    let thermalAllowed = thermal == .nominal || thermal == .fair
                    if (!allowed || !thermalAllowed) && self.generation == ticket { self.active = false }
                    self.lock.unlock()
                    guard allowed && thermalAllowed else { return }
                    let duty = thermal == .fair ? min(current.duty, 0.25) : current.duty
                    if index < current.workers && (thermal != .fair || index == 0) {
                        let deadline = start + 0.020 * duty
                        while ProcessInfo.processInfo.systemUptime < deadline {
                            value = self.batch(value)
                            self.lock.lock()
                            let keepGoing = self.active && self.generation == ticket && ContinuousClock.now < self.expires
                            self.lock.unlock()
                            if !keepGoing { return }
                        }
                    }
                    let rest = 0.020 - (ProcessInfo.processInfo.systemUptime - start)
                    if rest > 0 { Thread.sleep(forTimeInterval: rest) }
                }
            }
        }
    }
    func stop() {
        lock.lock(); active = false; generation += 1; launched = 0; expires = .now; plan = .stopped; lock.unlock()
    }
}

enum DischargeDecision: Equatable { case idle, discharge, cooldown, unavailable }
enum DischargePolicy {
    static func decide(config: Config, percentage: Int?, temperature: Double?, wasActive: Bool, cooling: Bool, thermal: ProcessInfo.ThermalState = .nominal) -> DischargeDecision {
        guard config.auto_discharge_enabled else { return .idle }
        guard let p = percentage, (0...100).contains(p), let temp = temperature, temp.isFinite, temp > 0 else { return .unavailable }
        if p <= config.low_battery_threshold { return .idle }
        guard wasActive || p >= config.high_battery_threshold else { return .idle }
        if temp >= AdaptiveLoadPolicy.temperatureLimit(config.temp_limit) || cooling { return .cooldown }
        if thermal != .nominal && thermal != .fair { return .cooldown }
        return .discharge
    }
}

actor IntegratedEngine {
    private var config: Config
    private let configURL: URL
    private let hardware: HardwareLease
    private let load = BoundedLoad()
    private var loadPlan = LoadPlan.stopped
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
    init(configURL: URL? = nil, legacyConfigURLs: [URL]? = nil, sensorsEnabled: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.configURL = configURL ?? support.appendingPathComponent("BatteryCare/config.json")
        self.sensorsEnabled = sensorsEnabled
        hardware = HardwareLease()
        let legacy = legacyConfigURLs ?? (configURL == nil ? [
            support.appendingPathComponent("BatteryBar/config.json"),
            URL(fileURLWithPath: "/Library/Application Support/BatteryService/config.json")
        ] : [])
        var imported = false
        config = .safeDefault
        for (index, url) in ([self.configURL] + legacy).enumerated() {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode(Config.self, from: data), saved.isValid else { continue }
            config = saved; imported = index > 0; break
        }
        // Never resume CPU stress merely by opening the App or after a crash.
        config.auto_discharge_enabled = false
        if imported {
            do {
                try FileManager.default.createDirectory(at: self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(config).write(to: self.configURL, options: [.atomic])
            } catch { serviceError = error.localizedDescription }
        }
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
            temperature: .init(cpu_celsius: temp, limit_celsius: AdaptiveLoadPolicy.temperatureLimit(config.temp_limit)),
            auto_discharge: .init(enabled: config.auto_discharge_enabled, cycle_active: cycleActive, cpu_load_active: load.isActive, caffeinate_active: assertion != 0 && load.isActive), config: config)
        lastSnapshot = result
        return result
    }
    private func control(percentage: Int?, temperature: Double?) {
        let decision = DischargePolicy.decide(config: config, percentage: percentage, temperature: temperature, wasActive: cycleActive, cooling: Date() < coolingUntil, thermal: ProcessInfo.processInfo.thermalState)
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
            if decision == .discharge, cycleActive, adapterEnabled == false, let temperature { startLoad(temperature: temperature) }
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
                if let temperature, temperature >= AdaptiveLoadPolicy.temperatureLimit(config.temp_limit) ||
                    (ProcessInfo.processInfo.thermalState != .nominal && ProcessInfo.processInfo.thermalState != .fair) {
                    coolingUntil = Date().addingTimeInterval(Double(config.cool_down_sleep))
                }
            case .discharge:
                // Do not start CPU load until the hardware has acknowledged AC cutoff.
                if adapterEnabled != false { _ = try hardware.call("disable"); adapterEnabled = false }
                cycleActive = true; serviceError = nil
                if let temperature { startLoad(temperature: temperature) }
            }
        } catch {
            stopLoad(); cycleActive = false; config.auto_discharge_enabled = false
            _ = try? hardware.call("enable"); adapterEnabled = nil
            serviceError = error.localizedDescription; try? persist()
        }
    }
    private func startLoad(temperature: Double) {
        loadPlan = AdaptiveLoadPolicy.plan(temperature: temperature, limit: config.temp_limit,
            thermal: ProcessInfo.processInfo.thermalState, processors: ProcessInfo.processInfo.activeProcessorCount,
            previous: load.isActive ? loadPlan : .stopped)
        guard loadPlan != .stopped else { stopLoad(); return }
        load.renew(plan: loadPlan)
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
        load.stop(); loadPlan = .stopped
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
