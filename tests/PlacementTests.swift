// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main struct PlacementTests {
    static func main() {
        let suite = "BatteryCare.MenuBarPositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        MenuBarPosition.prepare(defaults: defaults)
        precondition(defaults.integer(forKey: MenuBarPosition.preferredPositionKey) == 1)
        defaults.set(420, forKey: MenuBarPosition.preferredPositionKey)
        MenuBarPosition.prepare(defaults: defaults)
        precondition(defaults.integer(forKey: MenuBarPosition.preferredPositionKey) == 420)
        MenuBarPosition.prepare(defaults: defaults, reset: true)
        precondition(defaults.integer(forKey: MenuBarPosition.preferredPositionKey) == 1)
        precondition(MenuBarPosition.autosaveName == "BatteryCare.MainBattery")
        print("PASS right-side initial hint, remembered manual placement, explicit reset")
        let cases: [(String, NSRect, NSRect, NSSize)] = [
            ("main display", NSRect(x: 1200, y: 958, width: 64, height: 24), NSRect(x: 0, y: 38, width: 1512, height: 920), NSSize(width: 360, height: 500)),
            ("right edge", NSRect(x: 1490, y: 958, width: 22, height: 24), NSRect(x: 0, y: 38, width: 1512, height: 920), NSSize(width: 360, height: 500)),
            ("left edge", NSRect(x: 0, y: 958, width: 22, height: 24), NSRect(x: 0, y: 38, width: 1512, height: 920), NSSize(width: 360, height: 500)),
            ("display left of primary", NSRect(x: -420, y: 1056, width: 64, height: 24), NSRect(x: -1920, y: 0, width: 1920, height: 1056), NSSize(width: 360, height: 500)),
            ("display above primary", NSRect(x: 1200, y: 2056, width: 64, height: 24), NSRect(x: 0, y: 1080, width: 1920, height: 976), NSSize(width: 360, height: 500)),
            ("display below primary", NSRect(x: 800, y: -24, width: 64, height: 24), NSRect(x: 0, y: -1080, width: 1920, height: 1056), NSSize(width: 360, height: 500)),
            ("short display scrolls", NSRect(x: 800, y: 426, width: 64, height: 24), NSRect(x: 0, y: 0, width: 1024, height: 426), NSSize(width: 360, height: 800)),
            ("non-zero screen origin", NSRect(x: 3000, y: 1400, width: 64, height: 24), NSRect(x: 1920, y: 400, width: 1680, height: 1000), NSSize(width: 360, height: 530))
        ]
        for (name, anchor, visible, size) in cases {
            let frame = StatusPanelPlacement.frame(anchor: anchor, visibleFrame: visible, contentSize: size)
            precondition(visible.insetBy(dx: 8, dy: 8).contains(frame), "Outside screen: \(name)")
            precondition(frame.maxY <= anchor.minY, "Above menu bar: \(name)")
            print("PASS \(name): \(NSStringFromRect(frame))")
        }
        for i in 0..<2000 {
            let x = CGFloat((i * 137) % 6000 - 3000), y = CGFloat((i * 43) % 4000 - 2000)
            let width = CGFloat(600 + i % 1900), height = CGFloat(300 + i % 1200)
            let visible = NSRect(x: x, y: y, width: width, height: height)
            let anchor = NSRect(x: x + CGFloat(i % Int(width)), y: visible.maxY, width: 64, height: 24)
            let size = NSSize(width: 360, height: 450 + i % 400)
            let frame = StatusPanelPlacement.frame(anchor: anchor, visibleFrame: visible, contentSize: size)
            precondition(visible.insetBy(dx: 8, dy: 8).contains(frame))
            precondition(frame.maxY <= anchor.minY)
        }
        print("PASS 2000 generated multi-display placements")
    }
}
