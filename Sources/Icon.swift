// Original BatteryCare vector artwork. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let iconset = destination.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
}
func drawMark() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0x253057).withAlphaComponent(0.18); shadow.shadowBlurRadius = 20; shadow.shadowOffset = NSSize(width: 0, height: 8); shadow.set()
    color(0xf7f8fd).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0xffffff), color(0xf1f3fa), color(0xe2e7f5)])!.draw(in: tile, angle: 65)
    NSColor.white.withAlphaComponent(0.9).setStroke(); tile.lineWidth = 3; tile.stroke()
    let battery = NSBezierPath(roundedRect: NSRect(x: 200, y: 326, width: 568, height: 372), xRadius: 86, yRadius: 86)
    NSGraphicsContext.saveGraphicsState()
    let shadow2 = NSShadow(); shadow2.shadowColor = color(0x645de6).withAlphaComponent(0.28); shadow2.shadowBlurRadius = 36; shadow2.shadowOffset = NSSize(width: 0, height: 20); shadow2.set()
    color(0x7799ed).setFill(); battery.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0x5a67ed), color(0x31b8f0), color(0x39d8c0), color(0xafd96b), color(0xffc065), color(0xf48baf), color(0xb075ec)])!.draw(in: battery, angle: -25)
    NSColor.white.withAlphaComponent(0.55).setStroke(); battery.lineWidth = 5; battery.stroke()
    NSGradient(colors: [color(0xbc9bf0), color(0x8b7ce1)])!.draw(in: NSBezierPath(roundedRect: NSRect(x: 790, y: 440, width: 36, height: 144), xRadius: 17, yRadius: 17), angle: 90)
    let bolt = NSBezierPath(); bolt.move(to: NSPoint(x: 535, y: 369)); bolt.line(to: NSPoint(x: 402, y: 538)); bolt.line(to: NSPoint(x: 481, y: 538)); bolt.line(to: NSPoint(x: 447, y: 655)); bolt.line(to: NSPoint(x: 588, y: 479)); bolt.line(to: NSPoint(x: 506, y: 479)); bolt.close()
    NSColor.white.withAlphaComponent(0.97).setFill(); bolt.fill()
}
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: CGFloat(pixels)); context.scaleBy(x: CGFloat(pixels)/1024, y: -CGFloat(pixels)/1024)
        drawMark(); NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
        if pixels == 1024 { try png.write(to: destination.appendingPathComponent("logo.png")) }
    }
}
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); task.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent("AppIcon.icns").path]; try task.run(); task.waitUntilExit()
if task.terminationStatus != 0 { exit(task.terminationStatus) }
try FileManager.default.removeItem(at: iconset)
