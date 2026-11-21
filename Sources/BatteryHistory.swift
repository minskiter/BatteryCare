// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

enum HistoryPeriod: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30
    var id: Int { rawValue }
    var seconds: TimeInterval { Double(rawValue) * 86_400 }
    var key: String { "history.period.\(rawValue)" }
}

struct BatteryHistorySample: Equatable {
    var date: Date
    var session: String
    var percentage: Int?
    var health: Int?
    var cycles: Int?
    var charging: Bool?
    var plugged: Bool?
    var temperature: Double?
    var automatic: Bool
}

struct HistoryPoint: Identifiable {
    var date: Date
    var value: Double
    var segment: Int
    var id: Date { date }
}

enum HealthProjection {
    case insufficient, unstable, alreadyBelow
    // A scenario range, NOT a statistical confidence interval or warranty.
    case range(Date, Date)
}

struct BatteryHistoryReport {
    var points: [HistoryPoint] = []
    var healthPoints: [HistoryPoint] = []
    var sampleCount = 0
    var observedSeconds: Double = 0
    var dischargeSeconds: Double = 0
    var consumedPercentagePoints: Double = 0
    var ratePerHour: Double?
    var cycleIncrease: Int?
    var healthChange: Double?
    var firstRecord: Date?
    var projection = HealthProjection.insufficient
}

enum BatteryHistoryAnalysis {
    static let maxGap: TimeInterval = 180
    static func summarize(_ samples: [BatteryHistorySample], since: Date, until: Date) -> BatteryHistoryReport {
        var result = BatteryHistoryReport()
        let ordered = samples.filter { $0.date <= until }.sorted { $0.date < $1.date }
        let inWindow = ordered.filter { $0.date >= since }
        result.sampleCount = inWindow.count
        let cycles = inWindow.compactMap(\.cycles)
        if let first = cycles.first, let last = cycles.last,
           zip(cycles, cycles.dropFirst()).allSatisfy({ $0 <= $1 }) { result.cycleIncrease = last - first }
        let health = inWindow.compactMap(\.health)
        if let first = health.first, let last = health.last { result.healthChange = Double(last - first) }
        var segment = 0
        for (index, sample) in ordered.enumerated() {
            let previous = index > 0 ? ordered[index - 1] : nil
            let dt = previous.map { sample.date.timeIntervalSince($0.date) } ?? 0
            let consecutive = previous.map { $0.session == sample.session && dt > 0 && dt <= maxGap } ?? false
            if !consecutive || previous?.percentage == nil || sample.percentage == nil { segment += 1 }
            if sample.date >= since, let p = sample.percentage {
                result.points.append(.init(date: sample.date, value: Double(p), segment: segment))
            }
            guard consecutive, let previous, previous.percentage != nil, sample.percentage != nil else { continue }
            let overlap = sample.date.timeIntervalSince(max(previous.date, since))
            guard overlap > 0 else { continue }
            result.observedSeconds += overlap
            if previous.charging == false, sample.charging == false,
               previous.plugged == false, sample.plugged == false,
               let before = previous.percentage, let after = sample.percentage, after <= before {
                result.dischargeSeconds += overlap
                result.consumedPercentagePoints += Double(before - after) * overlap / dt
            }
        }
        // Integer capacity readings are too coarse for a short instantaneous rate.
        if result.dischargeSeconds >= 900, result.consumedPercentagePoints >= 2 {
            result.ratePerHour = result.consumedPercentagePoints / (result.dischargeSeconds / 3600)
        }
        result.points = downsample(result.points)
        return result
    }
    static func downsample(_ points: [HistoryPoint], limit: Int = 800) -> [HistoryPoint] {
        guard points.count > limit else { return points }
        let width = max(4, Int(ceil(Double(points.count) / Double(limit / 4))))
        var reduced: [HistoryPoint] = []
        for start in stride(from: 0, to: points.count, by: width) {
            let bucket = Array(points[start..<min(points.count, start + width)])
            // Keep both ends of each segment so a gap never becomes a false line.
            for group in Dictionary(grouping: bucket, by: \.segment).values {
                let candidates = [group.first!, group.min(by: { $0.value < $1.value })!,
                                  group.max(by: { $0.value < $1.value })!, group.last!]
                var seen = Set<Date>()
                reduced += candidates.sorted { $0.date < $1.date }.filter { seen.insert($0.date).inserted }
            }
        }
        reduced.sort { $0.date < $1.date }
        guard reduced.count > limit else { return reduced }
        return (0..<limit).map { reduced[$0 * (reduced.count - 1) / (limit - 1)] }
    }
    private static func fit(_ points: [HistoryPoint]) -> (slope: Double, r2: Double)? {
        guard let origin = points.first?.date, points.count >= 3 else { return nil }
        let xs = points.map { $0.date.timeIntervalSince(origin) / 86_400 }
        let ys = points.map(\.value)
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let xx = xs.reduce(0) { $0 + pow($1 - mx, 2) }
        let yy = ys.reduce(0) { $0 + pow($1 - my, 2) }
        guard xx > 0, yy > 0 else { return nil }
        let xy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return (xy / xx, min(1, xy * xy / (xx * yy)))
    }
    static func project(_ days: [HistoryPoint], now: Date, latestHealth: Int? = nil) -> HealthProjection {
        guard let last = days.last else { return .insufficient }
        guard (0..<3 * 86_400).contains(now.timeIntervalSince(last.date)) else { return .insufficient }
        let currentHealth = latestHealth.map(Double.init) ?? last.value
        if currentHealth < 80 { return .alreadyBelow }
        guard let first = days.first, days.count >= 14,
              last.date.timeIntervalSince(first.date) >= 28 * 86_400 else { return .insufficient }
        // Reject long gaps and large upward recalibration. No extrapolation from
        // discharge speed or Apple's rated cycle count.
        guard zip(days, days.dropFirst()).allSatisfy({
            $1.date.timeIntervalSince($0.date) <= 7 * 86_400 && $1.value - $0.value < 3
        }), first.value - last.value >= 2, let full = fit(days), full.r2 >= 0.7 else { return .unstable }
        let midpoint = first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) / 2)
        guard let early = fit(days.filter { $0.date <= midpoint }),
              let late = fit(days.filter { $0.date >= midpoint }) else { return .unstable }
        let rates = [full.slope, early.slope, late.slope].map { -$0 }
        guard let slow = rates.min(), let fast = rates.max(), slow > 0.005,
              fast / slow <= 3 else { return .unstable }
        // Target 79: the first integer health reading strictly below 80%.
        // +/- 1 point brackets coarse reporting; this is a heuristic scenario.
        let remaining = currentHealth - 79
        let earliest = max(1, (remaining - 1) / fast)
        let latest = (remaining + 1) / slow
        guard latest.isFinite, latest <= 5 * 365 else { return .unstable }
        return .range(now.addingTimeInterval(earliest * 86_400), now.addingTimeInterval(latest * 86_400))
    }
}

// One process, one actor-owned connection; no polling, hardware control or network.
// Snapshot sampling is throttled to one small row/minute and retains 365 days.
actor BatteryHistoryStore {
    private let url: URL
    private var db: OpaquePointer?
    private var session = UUID().uuidString
    private var lastDate: Date?
    private var lastCycles: Int?
    private var powerObserved = false
    private var lastCharging: Bool?
    private var lastPlugged: Bool?
    private var resetSince: TimeInterval = 0
    private var lastPrune = Date.distantPast
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryCare/history.sqlite3")
    }
    deinit { if let db { sqlite3_close(db) } }
    private func failure() -> EngineFailure {
        EngineFailure(detail: "电量历史存储失败：" + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite"))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); if let db { sqlite3_close(db) }; db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 1500)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try execute("""
                CREATE TABLE IF NOT EXISTS samples(
                  id INTEGER PRIMARY KEY, time REAL NOT NULL, session TEXT NOT NULL,
                  percentage INTEGER, health INTEGER, cycles INTEGER, charging INTEGER,
                  plugged INTEGER, temperature REAL, automatic INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS samples_time ON samples(time);
                CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value REAL NOT NULL);
                """)
            let stmt = try statement("SELECT cycles FROM samples WHERE cycles IS NOT NULL ORDER BY id DESC LIMIT 1")
            if sqlite3_step(stmt) == SQLITE_ROW { lastCycles = Int(sqlite3_column_int(stmt, 0)) }
            sqlite3_finalize(stmt)
            let meta = try statement("SELECT value FROM metadata WHERE key='health_reset'")
            if sqlite3_step(meta) == SQLITE_ROW { resetSince = sqlite3_column_double(meta, 0) }
            sqlite3_finalize(meta)
        } catch {
            if let db { sqlite3_close(db) }; db = nil; throw error
        }
    }
    @discardableResult func record(_ snapshot: Snapshot, at date: Date = Date()) throws -> Bool {
        try open()
        let b = snapshot.battery
        // Observe transitions even when the row itself is throttled. A brief
        // charge/unknown/invalid interval must not become continuous discharge.
        if (powerObserved && (b.is_charging != lastCharging || b.is_plugged_in != lastPlugged)) ||
            b.percentage.map({ !(0...100).contains($0) }) != false {
            session = UUID().uuidString
        }
        powerObserved = true; lastCharging = b.is_charging; lastPlugged = b.is_plugged_in
        if let lastDate {
            let dt = date.timeIntervalSince(lastDate)
            if dt >= 0 && dt < 60 { return false }
            if dt < 0 { session = UUID().uuidString }
        }
        let percent = b.percentage.flatMap { (0...100).contains($0) ? $0 : nil }
        let health = b.health_percentage.flatMap { (1...100).contains($0) ? $0 : nil }
        let cycles = b.cycle_count.flatMap { $0 >= 0 ? $0 : nil }
        // Cycle rollback indicates replacement/recalibration: do not fit the old
        // battery's health trend through the new battery's readings.
        if let cycles, let lastCycles, cycles < lastCycles {
            let meta = try statement("INSERT OR REPLACE INTO metadata VALUES('health_reset', ?)")
            sqlite3_bind_double(meta, 1, date.timeIntervalSince1970)
            defer { sqlite3_finalize(meta) }
            guard sqlite3_step(meta) == SQLITE_DONE else { throw failure() }
            resetSince = date.timeIntervalSince1970
        }
        let stmt = try statement("INSERT INTO samples(time,session,percentage,health,cycles,charging,plugged,temperature,automatic) VALUES(?,?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 2, session, -1, transient)
        for (index, value) in [(3, percent), (4, health), (5, cycles),
                               (6, b.is_charging.map { $0 ? 1 : 0 }), (7, b.is_plugged_in.map { $0 ? 1 : 0 })] {
            if let value { sqlite3_bind_int64(stmt, Int32(index), Int64(value)) }
            else { sqlite3_bind_null(stmt, Int32(index)) }
        }
        if let temp = snapshot.temperature.cpu_celsius, temp.isFinite, temp > 0, temp < 150 {
            sqlite3_bind_double(stmt, 8, temp)
        } else { sqlite3_bind_null(stmt, 8) }
        sqlite3_bind_int(stmt, 9, snapshot.auto_discharge.enabled ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        lastDate = date
        if let cycles { lastCycles = cycles }
        if date.timeIntervalSince(lastPrune) >= 86_400 {
            let prune = try statement("DELETE FROM samples WHERE time < ?")
            defer { sqlite3_finalize(prune) }
            sqlite3_bind_double(prune, 1, date.addingTimeInterval(-365 * 86_400).timeIntervalSince1970)
            guard sqlite3_step(prune) == SQLITE_DONE else { throw failure() }
            lastPrune = date
        }
        return true
    }
    private func samples(since: Date, until: Date) throws -> [BatteryHistorySample] {
        let stmt = try statement("SELECT time,session,percentage,health,cycles,charging,plugged,temperature,automatic FROM samples WHERE time>=? AND time<=? ORDER BY time,id")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        var result: [BatteryHistorySample] = []
        func integer(_ i: Int32) -> Int? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, i)) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(.init(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                session: String(cString: sqlite3_column_text(stmt, 1)),
                percentage: integer(2), health: integer(3), cycles: integer(4),
                charging: integer(5).map { $0 != 0 }, plugged: integer(6).map { $0 != 0 },
                temperature: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                automatic: sqlite3_column_int(stmt, 8) != 0))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }
    func report(period: HistoryPeriod, now: Date = Date()) throws -> BatteryHistoryReport {
        try open()
        let since = now.addingTimeInterval(-period.seconds)
        var result = BatteryHistoryAnalysis.summarize(try samples(since: since.addingTimeInterval(-180), until: now), since: since, until: now)
        let first = try statement("SELECT MIN(time) FROM samples WHERE time<=?")
        sqlite3_bind_double(first, 1, now.timeIntervalSince1970)
        if sqlite3_step(first) == SQLITE_ROW, sqlite3_column_type(first, 0) != SQLITE_NULL {
            result.firstRecord = Date(timeIntervalSince1970: sqlite3_column_double(first, 0))
        }
        sqlite3_finalize(first)
        let health = try statement("""
            SELECT CAST(time/86400 AS INTEGER), AVG(health)
            FROM samples WHERE time>=? AND time<=? AND health IS NOT NULL
            GROUP BY CAST(time/86400 AS INTEGER) ORDER BY 1
            """)
        defer { sqlite3_finalize(health) }
        sqlite3_bind_double(health, 1, max(resetSince, now.addingTimeInterval(-180 * 86_400).timeIntervalSince1970))
        sqlite3_bind_double(health, 2, now.timeIntervalSince1970)
        var days: [HistoryPoint] = []
        var segment = 0
        var status = sqlite3_step(health)
        while status == SQLITE_ROW {
            let date = Date(timeIntervalSince1970: sqlite3_column_double(health, 0) * 86_400)
            if let previous = days.last, date.timeIntervalSince(previous.date) > 3 * 86_400 { segment += 1 }
            days.append(.init(date: date, value: sqlite3_column_double(health, 1), segment: segment))
            status = sqlite3_step(health)
        }
        guard status == SQLITE_DONE else { throw failure() }
        result.healthPoints = days
        let latest = try statement("SELECT health FROM samples WHERE health IS NOT NULL AND time>=? AND time<=? ORDER BY time DESC,id DESC LIMIT 1")
        defer { sqlite3_finalize(latest) }
        sqlite3_bind_double(latest, 1, max(resetSince, now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970))
        sqlite3_bind_double(latest, 2, now.timeIntervalSince1970)
        if sqlite3_step(latest) == SQLITE_ROW {
            result.projection = BatteryHistoryAnalysis.project(days, now: now, latestHealth: Int(sqlite3_column_int(latest, 0)))
        }
        return result
    }
    func exportCSV(now: Date = Date()) throws -> String {
        try open()
        let rows = try samples(since: now.addingTimeInterval(-365 * 86_400), until: now)
        var csv = "timestamp_utc,battery_percent,health_percent,cycle_count,is_charging,external_power,cpu_celsius,auto_discharge\n"
        let formatter = ISO8601DateFormatter()
        for row in rows {
            csv += [formatter.string(from: row.date), row.percentage.map(String.init) ?? "",
                    row.health.map(String.init) ?? "", row.cycles.map(String.init) ?? "",
                    row.charging.map { $0 ? "1" : "0" } ?? "", row.plugged.map { $0 ? "1" : "0" } ?? "",
                    row.temperature.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "",
                    row.automatic ? "1" : "0"].joined(separator: ",") + "\n"
        }
        return csv
    }
    func clear() throws {
        try open()
        try execute("BEGIN; DELETE FROM samples; DELETE FROM metadata; COMMIT;")
        lastDate = nil; lastCycles = nil; resetSince = 0; session = UUID().uuidString
        powerObserved = false
    }
    func breakContinuity() {
        session = UUID().uuidString
        powerObserved = false
    }
}
