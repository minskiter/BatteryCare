// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation

@main struct IconTests {
    @MainActor static func main() throws {
        let model = BatteryModel(poll: false)
        let fixture = """
        {"service":{"running":true},"battery":{"percentage":98,"charging_state":"discharging","is_charging":false,"is_plugged_in":false},"temperature":{"cpu_celsius":52,"limit_celsius":80},"auto_discharge":{"enabled":true,"cycle_active":true,"cpu_load_active":true,"caffeinate_active":true},"config":{"auto_discharge_enabled":true,"low_battery_threshold":10,"high_battery_threshold":20,"temp_limit":80,"cool_down_sleep":30,"loop_interval":60}}
        """
        model.status = try JSONDecoder().decode(Snapshot.self, from: Data(fixture.utf8))
        model.connected = true
        precondition(model.enabled && !model.isCharging && !model.batterySymbol.contains("bolt"))
        print("PASS automatic discharge never implies charging lightning")
        model.status?.battery.is_plugged_in = true
        precondition(!model.batterySymbol.contains("bolt"))
        print("PASS external power without charging has no lightning")
        model.status?.battery.charging_state = "charged"
        precondition(!model.batterySymbol.contains("bolt") && model.chargingDescription.contains("未在充电"))
        print("PASS fully charged does not show charging lightning")
        model.status?.config.auto_discharge_enabled = false
        model.status?.battery.is_charging = true
        model.status?.battery.charging_state = "charging"
        precondition(model.isCharging && model.batterySymbol.contains("bolt"))
        print("PASS actual charging shows lightning even when automation is off")
        model.connected = false
        precondition(!model.isCharging && !model.batterySymbol.contains("bolt"))
        print("PASS offline stale charging data never shows lightning")
        model.connected = true; model.status?.battery.is_charging = nil
        precondition(!model.batterySymbol.contains("bolt"))
        print("PASS unknown charging state never shows lightning")
        for (percentage, symbol) in [(0,"battery.0percent"),(12,"battery.0percent"),(13,"battery.25percent"),(37,"battery.25percent"),(38,"battery.50percent"),(62,"battery.50percent"),(63,"battery.75percent"),(87,"battery.75percent"),(88,"battery.100percent"),(100,"battery.100percent")] {
            precondition(BatteryIcon.symbol(percentage: percentage, isCharging: false) == symbol)
        }
        print("PASS battery-fill threshold boundaries")
        precondition(NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: nil) != nil)
        print("All icon tests passed; no system settings or battery state were changed.")
    }
}
