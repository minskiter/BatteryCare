// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct HistoryTests {
    static func sample(_ date: Date, _ percent: Int?, session: String = "A") -> BatteryHistorySample {
        .init(date: date, session: session, percentage: percent, health: 82, cycles: 509,
              charging: false, plugged: false, temperature: 50, automatic: false)
    }
    static func snapshot(_ percent: Int?, health: Int? = 82, cycles: Int? = 509) -> Snapshot {
        .init(service: .init(running: true, last_update: nil, last_error: nil),
              battery: .init(percentage: percent, charging_state: "discharging", power_source: "Battery Power",
                             is_charging: false, is_plugged_in: false, cycle_count: cycles, health_percentage: health),
              temperature: .init(cpu_celsius: 50, limit_celsius: 75),
              auto_discharge: .init(enabled: false, cycle_active: false, cpu_load_active: false, caffeinate_active: false),
              config: .safeDefault)
    }
    static func main() async throws {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let hour = (0...60).map { sample(origin.addingTimeInterval(Double($0) * 60), 80 - $0 / 5) }
        let report = BatteryHistoryAnalysis.summarize(hour, since: origin, until: origin.addingTimeInterval(3600))
        precondition(report.sampleCount == 61 && report.consumedPercentagePoints == 12)
        precondition(report.observedSeconds == 3600 && report.dischargeSeconds == 3600 && report.ratePerHour == 12)
        precondition(report.cycleIncrease == 0 && report.healthChange == 0)
        let partial = BatteryHistoryAnalysis.summarize(hour, since: origin.addingTimeInterval(30), until: origin.addingTimeInterval(3600))
        precondition(partial.observedSeconds == 3570)
        precondition(BatteryHistoryAnalysis.summarize(Array(hour.prefix(5)), since: origin, until: origin.addingTimeInterval(3600)).ratePerHour == nil)
        print("PASS cumulative percentage-point consumption, observation duration, window clipping and coarse-rate guard")

        var plugged = hour
        for i in plugged.indices { plugged[i].plugged = true }
        precondition(BatteryHistoryAnalysis.summarize(plugged, since: origin, until: origin.addingTimeInterval(3600)).consumedPercentagePoints == 0)
        for i in plugged.indices { plugged[i].plugged = nil }
        precondition(BatteryHistoryAnalysis.summarize(plugged, since: origin, until: origin.addingTimeInterval(3600)).ratePerHour == nil)
        let gap = [sample(origin, 90), sample(origin.addingTimeInterval(3600), 70)]
        let gapReport = BatteryHistoryAnalysis.summarize(gap, since: origin, until: origin.addingTimeInterval(3600))
        precondition(gapReport.consumedPercentagePoints == 0 && gapReport.observedSeconds == 0)
        precondition(gapReport.points[0].segment != gapReport.points[1].segment)
        let restart = [sample(origin, 90), sample(origin.addingTimeInterval(60), 70, session: "B")]
        precondition(BatteryHistoryAnalysis.summarize(restart, since: origin, until: origin.addingTimeInterval(3600)).consumedPercentagePoints == 0)
        let missing = [sample(origin, 90), sample(origin.addingTimeInterval(60), nil), sample(origin.addingTimeInterval(120), 70)]
        precondition(BatteryHistoryAnalysis.summarize(missing, since: origin, until: origin.addingTimeInterval(3600)).consumedPercentagePoints == 0)
        let rise = [sample(origin, 80), sample(origin.addingTimeInterval(60), 82)]
        precondition(BatteryHistoryAnalysis.summarize(rise, since: origin, until: origin.addingTimeInterval(3600)).consumedPercentagePoints == 0)
        print("PASS charging/unknown-power exclusion, sleep gaps, app restarts, missing sensors and upward corrections")

        let dense = (0..<20_000).map {
            HistoryPoint(date: origin.addingTimeInterval(Double($0) * 60), value: Double($0 % 100), segment: $0 / 1000)
        }
        let sparse = BatteryHistoryAnalysis.downsample(dense)
        precondition(sparse.count <= 800 && sparse.first?.date == dense.first?.date && sparse.last?.date == dense.last?.date)
        let pathological = dense.enumerated().map { HistoryPoint(date: $0.element.date, value: $0.element.value, segment: $0.offset) }
        precondition(BatteryHistoryAnalysis.downsample(pathological).count <= 800)
        print("PASS bounded chart downsampling, endpoints and separated segments")

        let days = (0..<61).map { HistoryPoint(date: origin.addingTimeInterval(Double($0) * 86_400), value: 95 - Double($0) * 0.15, segment: 0) }
        let now = days.last!.date.addingTimeInterval(3600)
        if case .range(let early, let late) = BatteryHistoryAnalysis.project(days, now: now) {
            precondition(early > now && late >= early)
        } else { preconditionFailure("Stable long-term trend should produce a scenario range") }
        if case .insufficient = BatteryHistoryAnalysis.project(Array(days.prefix(14)), now: days[13].date) {} else { preconditionFailure() }
        let flat = days.map { HistoryPoint(date: $0.date, value: 82, segment: 0) }
        if case .unstable = BatteryHistoryAnalysis.project(flat, now: now) {} else { preconditionFailure() }
        if case .insufficient = BatteryHistoryAnalysis.project(days, now: now.addingTimeInterval(4 * 86_400)) {} else { preconditionFailure() }
        let below = [HistoryPoint(date: now, value: 79, segment: 0)]
        if case .alreadyBelow = BatteryHistoryAnalysis.project(below, now: now) {} else { preconditionFailure() }
        if case .alreadyBelow = BatteryHistoryAnalysis.project(days, now: now, latestHealth: 79) {} else { preconditionFailure() }
        let recovery = days.enumerated().map { index, point in
            HistoryPoint(date: point.date, value: index < 30 ? 95 - Double(index) * 0.15 : 90 + Double(index - 30) * 0.05, segment: 0)
        }
        if case .unstable = BatteryHistoryAnalysis.project(recovery, now: now) {} else { preconditionFailure() }
        print("PASS forecast guards: 28-day minimum, sufficient dates, stable decline, flat/recovering/stale rejection and below-80 state")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryCare-history-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite3")
        let store = BatteryHistoryStore(url: url)
        let first = try await store.record(snapshot(80), at: origin)
        let throttled = try await store.record(snapshot(79), at: origin.addingTimeInterval(10))
        let second = try await store.record(snapshot(79), at: origin.addingTimeInterval(60))
        precondition(first && !throttled && second)
        var saved = try await store.report(period: .day, now: origin.addingTimeInterval(60))
        precondition(saved.sampleCount == 2 && saved.consumedPercentagePoints == 1 && saved.firstRecord == origin)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reopened = BatteryHistoryStore(url: url)
        _ = try await reopened.record(snapshot(77), at: origin.addingTimeInterval(120))
        saved = try await reopened.report(period: .day, now: origin.addingTimeInterval(120))
        precondition(saved.sampleCount == 3 && saved.consumedPercentagePoints == 1)
        let csv = try await reopened.exportCSV(now: origin.addingTimeInterval(120))
        precondition(csv.contains("timestamp_utc,battery_percent") && csv.split(separator: "\n").count == 4)
        precondition(csv.contains(",80,82,509,0,0,50.00,0"))
        print("PASS SQLite persistence, one-minute throttle, private file permissions, restart boundaries and CSV")
        _ = try await reopened.record(snapshot(101, health: 101, cycles: -1), at: origin.addingTimeInterval(180))
        saved = try await reopened.report(period: .day, now: origin.addingTimeInterval(180))
        precondition(saved.sampleCount == 4 && saved.points.count == 3)
        _ = try await reopened.record(snapshot(99, health: 100, cycles: 0), at: origin.addingTimeInterval(240))
        saved = try await reopened.report(period: .day, now: origin.addingTimeInterval(240))
        precondition(saved.healthPoints.count == 1 && saved.healthPoints[0].value == 100)
        let old = origin.addingTimeInterval(-400 * 86_400)
        let retention = BatteryHistoryStore(url: dir.appendingPathComponent("retention.sqlite3"))
        _ = try await retention.record(snapshot(80), at: old)
        _ = try await retention.record(snapshot(79), at: origin)
        let retained = try await retention.exportCSV(now: origin)
        precondition(retained.split(separator: "\n").count == 2)
        let boundaries = BatteryHistoryStore(url: dir.appendingPathComponent("boundaries.sqlite3"))
        _ = try await boundaries.record(snapshot(80), at: origin)
        _ = try await boundaries.record(snapshot(nil), at: origin.addingTimeInterval(10))
        _ = try await boundaries.record(snapshot(79), at: origin.addingTimeInterval(60))
        var separated = try await boundaries.report(period: .day, now: origin.addingTimeInterval(60))
        precondition(separated.consumedPercentagePoints == 0 && separated.observedSeconds == 0)
        var charging = snapshot(79); charging.battery.is_charging = true; charging.battery.is_plugged_in = true
        _ = try await boundaries.record(charging, at: origin.addingTimeInterval(70))
        _ = try await boundaries.record(snapshot(78), at: origin.addingTimeInterval(120))
        separated = try await boundaries.report(period: .day, now: origin.addingTimeInterval(120))
        precondition(separated.consumedPercentagePoints == 0)
        await boundaries.breakContinuity()
        _ = try await boundaries.record(snapshot(77), at: origin.addingTimeInterval(180))
        separated = try await boundaries.report(period: .day, now: origin.addingTimeInterval(180))
        precondition(separated.consumedPercentagePoints == 0)
        print("PASS sub-minute invalid/power transitions and explicit short sleep/wake boundaries")
        try await reopened.clear()
        saved = try await reopened.report(period: .month, now: origin.addingTimeInterval(240))
        precondition(saved.sampleCount == 0 && saved.firstRecord == nil && saved.healthPoints.isEmpty)
        _ = try await reopened.record(snapshot(90), at: origin.addingTimeInterval(241))
        saved = try await reopened.report(period: .day, now: origin.addingTimeInterval(241))
        precondition(saved.sampleCount == 1 && saved.consumedPercentagePoints == 0)
        let blocker = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let broken = BatteryHistoryStore(url: blocker.appendingPathComponent("history.sqlite3"))
        do { _ = try await broken.record(snapshot(80), at: origin); preconditionFailure("Expected IO failure") } catch {}
        print("PASS invalid readings, battery replacement trend reset, retention, clear/restart and isolated storage failure")
        print("All history tests passed; synthetic data only, no hardware or real user history touched.")
    }
}
