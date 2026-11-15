// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

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
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("work/integrated-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
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
