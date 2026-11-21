// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

// Test doubles only: worker lifecycle tests sleep instead of executing arithmetic.
final class LoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var state: ProcessInfo.ThermalState = .nominal
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var thermal: ProcessInfo.ThermalState { lock.lock(); defer { lock.unlock() }; return state }
    func setThermal(_ value: ProcessInfo.ThermalState) { lock.lock(); state = value; lock.unlock() }
    func batch(_ value: Double) -> Double {
        lock.lock(); count += 1; lock.unlock()
        Thread.sleep(forTimeInterval: 0.001)
        return value + 1
    }
}

@main struct IntegratedTests {
    static func main() async throws {
        var c = Config.safeDefault
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 55, wasActive: false, cooling: false) == .idle)
        c.auto_discharge_enabled = true
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 55, wasActive: false, cooling: false) == .discharge)
        precondition(DischargePolicy.decide(config: c, percentage: 15, temperature: 55, wasActive: false, cooling: false) == .idle)
        precondition(DischargePolicy.decide(config: c, percentage: 15, temperature: 55, wasActive: true, cooling: false) == .discharge)
        precondition(DischargePolicy.decide(config: c, percentage: 10, temperature: 55, wasActive: true, cooling: false) == .idle)
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 80, wasActive: true, cooling: false) == .cooldown)
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 50, wasActive: true, cooling: true) == .cooldown)
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: nil, wasActive: true, cooling: false) == .unavailable)
        precondition(DischargePolicy.decide(config: c, percentage: nil, temperature: 55, wasActive: true, cooling: false) == .unavailable)
        print("PASS hysteresis, threshold boundaries, temperature, cooldown, sensor loss")
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: invalid, wasActive: true, cooling: false) == .unavailable)
        }
        for invalid in [-1, 101] {
            precondition(DischargePolicy.decide(config: c, percentage: invalid, temperature: 55, wasActive: true, cooling: false) == .unavailable)
        }
        c.temp_limit = 100
        precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 75, wasActive: true, cooling: false) == .cooldown)
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            precondition(DischargePolicy.decide(config: c, percentage: 80, temperature: 50, wasActive: true, cooling: false, thermal: thermal) == .cooldown)
        }
        print("PASS non-finite/invalid sensor rejection, hard CPU cutoff and OS thermal stops")

        for processors in [-1, 1, 2, 4, 8, 16, 128] {
            let limit = AdaptiveLoadPolicy.workerLimit(processors: processors)
            precondition((1...4).contains(limit) && limit <= max(1, processors / 2))
            var previous = LoadPlan.stopped
            for _ in 0..<30 {
                let next = AdaptiveLoadPolicy.plan(temperature: 45, limit: 80, thermal: .nominal, processors: processors, previous: previous)
                precondition((1...limit).contains(next.workers) && next.duty > 0 && next.duty <= 0.85)
                precondition(Double(next.workers) * next.duty <= Double(previous.workers) * previous.duty + 0.250001)
                previous = next
            }
            precondition(abs(Double(previous.workers) * previous.duty - Double(limit) * 0.85) < 0.00001)
            let warm = AdaptiveLoadPolicy.plan(temperature: 74, limit: 80, thermal: .nominal, processors: processors, previous: previous)
            precondition(Double(warm.workers) * warm.duty < Double(previous.workers) * previous.duty)
            let fair = AdaptiveLoadPolicy.plan(temperature: 45, limit: 80, thermal: .fair, processors: processors, previous: previous)
            precondition(fair.workers == 1 && fair.duty <= 0.25)
            for state in [ProcessInfo.ThermalState.serious, .critical] {
                precondition(AdaptiveLoadPolicy.plan(temperature: 45, limit: 80, thermal: state, processors: processors, previous: previous) == .stopped)
            }
            for temp in [75, 80, Double.nan, .infinity, 0, -1] {
                precondition(AdaptiveLoadPolicy.plan(temperature: temp, limit: 80, thermal: .nominal, processors: processors, previous: previous) == .stopped)
            }
            precondition(AdaptiveLoadPolicy.plan(temperature: 60, limit: 60, thermal: .nominal, processors: processors, previous: previous) == .stopped)
        }
        print("PASS adaptive ramp, bounded cores/duty, immediate taper and thermal budgets")

        let probe = LoadProbe()
        let worker = BoundedLoad(workerCapacity: 2, leaseDuration: 0.08,
                                 thermalState: { probe.thermal }, batch: { probe.batch($0) })
        let testPlan = LoadPlan(workers: 1, duty: 0.25)
        worker.renew(plan: testPlan)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(!worker.isActive && probe.calls > 0)
        let expiredCalls = probe.calls
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(probe.calls == expiredCalls)
        worker.renew(plan: testPlan)
        precondition(worker.isActive)
        worker.stop()
        precondition(!worker.isActive)
        worker.renew(plan: testPlan)
        probe.setThermal(.critical)
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(!worker.isActive)
        probe.setThermal(.nominal)
        worker.renew(plan: testPlan)
        worker.renew(plan: .stopped)
        precondition(!worker.isActive)
        worker.renew(plan: LoadPlan(workers: 1, duty: .nan))
        precondition(!worker.isActive)
        print("PASS worker expiry, restart, cancellation and independent thermal guard (mock batches)")

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/integrated-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent("legacy/config.json")
        let migratedURL = dir.appendingPathComponent("BatteryCare/config.json")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        c.low_battery_threshold = 12; c.high_battery_threshold = 28
        try JSONEncoder().encode(c).write(to: legacyURL)
        let migration = IntegratedEngine(configURL: migratedURL, legacyConfigURLs: [legacyURL], sensorsEnabled: false)
        let migrated = await migration.getConfig()
        precondition(!migrated.auto_discharge_enabled && migrated.low_battery_threshold == 12 && migrated.high_battery_threshold == 28)
        let savedMigration = try JSONDecoder().decode(Config.self, from: Data(contentsOf: migratedURL))
        precondition(savedMigration == migrated)
        let legacyUnchanged = try JSONDecoder().decode(Config.self, from: Data(contentsOf: legacyURL))
        precondition(legacyUnchanged.auto_discharge_enabled)
        var canonical = migrated; canonical.high_battery_threshold = 35
        try JSONEncoder().encode(canonical).write(to: migratedURL)
        let preferred = IntegratedEngine(configURL: migratedURL, legacyConfigURLs: [legacyURL], sensorsEnabled: false)
        let preferredConfig = await preferred.getConfig()
        precondition(preferredConfig.high_battery_threshold == 35)
        try await preferred.shutdown(); try await migration.shutdown()
        print("PASS BatteryCare configuration migration, disabled startup, original preservation and canonical precedence")
        c.low_battery_threshold = 10; c.high_battery_threshold = 20
        let url = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(c).write(to: url)
        let engine = IntegratedEngine(configURL: url, sensorsEnabled: false)
        let restored = await engine.getConfig()
        precondition(!restored.auto_discharge_enabled && restored.low_battery_threshold == 10)
        print("PASS startup imports thresholds without resuming CPU stress")
        _ = try await engine.setConfig(["low_battery_threshold": 15, "high_battery_threshold": 30])
        do { _ = try await engine.setConfig(["low_battery_threshold": 90, "high_battery_threshold": 20]); preconditionFailure("invalid config accepted") } catch {}
        let current = await engine.getConfig()
        precondition(current.low_battery_threshold == 15 && current.high_battery_threshold == 30)
        do { _ = try await engine.setConfig(["arbitrary": true]); preconditionFailure("unknown key accepted") } catch {}
        print("PASS transactional parameter validation and persistence")
        let snapshot = await engine.snapshot()
        precondition(snapshot.service.running && !snapshot.auto_discharge.enabled && !snapshot.auto_discharge.cpu_load_active)
        _ = try JSONEncoder().encode(snapshot)
        try await engine.shutdown()
        let stopped = await engine.snapshot()
        precondition(!stopped.service.running && !stopped.auto_discharge.cpu_load_active)
        print("PASS in-process service startup/shutdown; no Python, HTTP, root or hardware writes")
    }
}
