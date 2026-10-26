// Renders the app icon PNG: swift make-icon.swift <out.png> <size>
import AppKit

let out = CommandLine.arguments[1]
let px = CGFloat(Double(CommandLine.arguments[2]) ?? 1024)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: ~80% artwork inset with a continuous rounded rect.
let inset = px * 0.1
let rect = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
let gradient = NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.95, alpha: 1),
                          ending: NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.70, alpha: 1))!
gradient.draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225), angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (px - s.width) / 2, y: (px - s.height) / 2, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
