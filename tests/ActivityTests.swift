// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

@main struct ActivityTests {
    @MainActor static func main() throws {
        let model = BatteryModel(poll: false)
        let fixture = """
        {"service":{"running":true},"battery":{"percentage":94,"charging_state":"discharging","is_charging":false,"is_plugged_in":false},"temperature":{"cpu_celsius":52,"limit_celsius":75},"auto_discharge":{"enabled":true,"cycle_active":true,"cpu_load_active":true,"caffeinate_active":true},"config":{"auto_discharge_enabled":true,"low_battery_threshold":10,"high_battery_threshold":20,"temp_limit":75,"cool_down_sleep":30,"loop_interval":60}}
        """
        model.status = try JSONDecoder().decode(Snapshot.self, from: Data(fixture.utf8))
        model.connected = true
        precondition(model.activity == .discharging && model.activity.symbol == "arrow.down")
        model.status?.temperature.cpu_celsius = nil
        precondition(model.activity == .unknown)
        model.status?.temperature.cpu_celsius = 52
        model.status?.battery.percentage = nil
        precondition(model.activity == .unknown)
        model.status?.battery.percentage = 94
        model.status?.auto_discharge.enabled = false
        precondition(model.activity == .battery)
        model.status?.auto_discharge.enabled = true
        model.status?.auto_discharge.cpu_load_active = false
        precondition(model.activity == .cooling && !model.activity.hasAnimation)
        model.status?.auto_discharge.cycle_active = false
        precondition(model.activity == .waiting && !model.activity.hasAnimation)
        model.status?.config.auto_discharge_enabled = false
        precondition(model.activity == .battery)
        model.status?.battery.is_plugged_in = true
        precondition(model.activity == .external)
        model.status?.battery.charging_state = "charged"
        precondition(model.activity == .full)
        model.status?.battery.is_charging = true
        precondition(model.activity == .charging)
        // Actual charging wins even if a stale automation flag disagrees.
        model.status?.config.auto_discharge_enabled = true
        model.status?.auto_discharge.cycle_active = true
        model.status?.auto_discharge.cpu_load_active = true
        precondition(model.activity == .charging)
        model.connected = false
        precondition(model.activity == .unknown && !model.activity.hasAnimation)
        model.connected = true; model.status?.service.running = false
        precondition(model.activity == .unknown)
        model.status = nil
        precondition(model.activity == .unknown)
        print("PASS actual load/charging, cooldown, waiting, battery, external, full and stale-state presentation")

        for activity in BatteryActivity.allCases {
            precondition(NSImage(systemSymbolName: activity.symbol, accessibilityDescription: nil) != nil)
            precondition(!activity.shouldAnimate(visible: false, reduceMotion: false))
            precondition(!activity.shouldAnimate(visible: true, reduceMotion: true))
            precondition(activity.shouldAnimate(visible: true, reduceMotion: false) == activity.hasAnimation)
            for language in AppLanguage.allCases {
                precondition(L10n.catalogs[language]?[activity.labelKey] != nil)
            }
        }
        precondition(BatteryGaugeArtwork(activity: .discharging, percentage: 94, phase: 0.5, animated: true).fill == 0.94)
        precondition(BatteryGaugeArtwork(activity: .unknown, percentage: nil, phase: 0, animated: false).fill == 0)
        precondition(BatteryGaugeArtwork(activity: .unknown, percentage: -1, phase: 0, animated: false).fill == 0)
        precondition(BatteryGaugeArtwork(activity: .full, percentage: 101, phase: 0, animated: false).fill == 1)
        print("PASS available symbols, all localized labels, hidden/reduced-motion animation gates and real percentage fill")
    }
}
