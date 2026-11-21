// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts

struct BatteryStatisticsPanel: View {
    @ObservedObject var model: BatteryModel
    private var report: BatteryHistoryReport { model.historyReport }
    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: model.language.rawValue)))
    }
    private func date(_ value: Date, includeTime: Bool = false) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: includeTime ? .shortened : .omitted)
            .locale(Locale(identifier: model.language.rawValue)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.text("history.title"), systemImage: "chart.xyaxis.line").font(.title2.bold())
                Spacer()
                Picker(L10n.text("history.period"), selection: $model.historyPeriod) {
                    ForEach(HistoryPeriod.allCases) { period in Text(L10n.text(period.key)).tag(period) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
            }
            Text(L10n.text("history.scope")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                metric("history.consumed", decimal(report.consumedPercentagePoints), "history.unit.points")
                metric("history.rate", report.ratePerHour.map(decimal) ?? "—", "history.unit.rate")
                metric("history.observed", decimal(report.observedSeconds / 3600), "history.unit.hours")
            }
            Card {
                Text(L10n.text("history.battery.chart")).font(.headline)
                if report.points.isEmpty {
                    emptyChart
                } else {
                    Chart(report.points) { point in
                        LineMark(x: .value(L10n.text("history.time"), point.date),
                                 y: .value(L10n.text("history.battery.chart"), point.value),
                                 series: .value("segment", point.segment))
                            .foregroundStyle(.green).interpolationMethod(.linear)
                        if report.points.count == 1 {
                            PointMark(x: .value(L10n.text("history.time"), point.date),
                                      y: .value(L10n.text("history.battery.chart"), point.value)).foregroundStyle(.green)
                        }
                    }.chartYScale(domain: 0...100).chartYAxisLabel("%").frame(height: 155)
                        .accessibilityLabel(L10n.text("history.battery.chart"))
                }
                Text(L10n.text("history.gaps")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(L10n.format("history.cycles", report.cycleIncrease.map(String.init) ?? "—"))
                    Spacer()
                    Text(L10n.format("history.health.change", report.healthChange.map { decimal($0) } ?? "—"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Text(L10n.text("history.health.chart")).font(.headline)
                if report.healthPoints.isEmpty {
                    emptyChart
                } else {
                    Chart {
                        ForEach(report.healthPoints) { point in
                            LineMark(x: .value(L10n.text("history.time"), point.date),
                                     y: .value(L10n.text("history.health.chart"), point.value),
                                     series: .value("segment", point.segment)).foregroundStyle(.blue)
                            PointMark(x: .value(L10n.text("history.time"), point.date),
                                      y: .value(L10n.text("history.health.chart"), point.value))
                                .foregroundStyle(.blue).symbolSize(12)
                        }
                        RuleMark(y: .value("80%", 80)).foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .chartYScale(domain: min(78, (report.healthPoints.map(\.value).min() ?? 80) - 2)...100)
                    .chartYAxisLabel("%").frame(height: 120)
                    .accessibilityLabel(L10n.text("history.health.chart"))
                }
                Text(L10n.text("history.forecast.title")).font(.subheadline.bold())
                Text(projectionText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("history.forecast.hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.historyError {
                Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                if let first = report.firstRecord {
                    Text(L10n.format("history.since", date(first, includeTime: true)))
                } else { Text(L10n.text("history.empty")) }
                Spacer()
                Button(L10n.text("history.export")) { model.exportHistory() }
                Button(L10n.text("history.clear")) { model.clearHistory() }
            }.font(.caption)
            Text(L10n.text("history.storage.hint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).environment(\.locale, Locale(identifier: model.language.rawValue))
        .onChange(of: model.historyPeriod) { _ in Task { await model.refreshHistory() } }
    }
    private var emptyChart: some View {
        Text(L10n.text("history.empty")).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 90)
    }
    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        Card {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(L10n.text(unit)).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private var projectionText: String {
        switch report.projection {
        case .insufficient: return L10n.text("history.forecast.insufficient")
        case .unstable: return L10n.text("history.forecast.unstable")
        case .alreadyBelow: return L10n.text("history.forecast.below")
        case .range(let early, let late):
            return L10n.format("history.forecast.range",
                date(early) + " – " + date(late))
        }
    }
}
