// Renders Resources/Sayso.icns: dark tile with an ember speech bubble holding text and a caret.
import AppKit
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    // Dark ink tile, ember speech bubble, cream text caret: "say it, get text".
    let tile = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(starting: NSColor(red: 0.17, green: 0.15, blue: 0.20, alpha: 1), ending: NSColor(red: 0.09, green: 0.08, blue: 0.11, alpha: 1))!
        .draw(in: tile, angle: -90)
    let w = box.width
    let bubble = NSRect(x: box.minX + w * 0.18, y: box.minY + w * 0.30, width: w * 0.64, height: w * 0.48)
    let path = NSBezierPath(roundedRect: bubble, xRadius: w * 0.16, yRadius: w * 0.16)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubble.minX + w * 0.14, y: bubble.minY + w * 0.02))
    tail.line(to: NSPoint(x: bubble.minX + w * 0.08, y: box.minY + w * 0.16))
    tail.line(to: NSPoint(x: bubble.minX + w * 0.30, y: bubble.minY + w * 0.02))
    tail.close()
    path.append(tail)
    NSGradient(starting: NSColor(red: 0.98, green: 0.78, blue: 0.52, alpha: 1), ending: NSColor(red: 0.94, green: 0.54, blue: 0.36, alpha: 1))!
        .draw(in: path, angle: -90)
    NSColor(red: 0.12, green: 0.11, blue: 0.14, alpha: 1).setFill()
    let caretW = w * 0.055, caretH = w * 0.26
    NSBezierPath(roundedRect: NSRect(x: bubble.midX - caretW / 2 + w * 0.06, y: bubble.midY - caretH / 2, width: caretW, height: caretH),
                 xRadius: caretW / 2, yRadius: caretW / 2).fill()
    for (i, len) in [0.20, 0.13].enumerated() {
        let y = bubble.midY + (i == 0 ? w * 0.04 : -w * 0.08)
        NSBezierPath(roundedRect: NSRect(x: bubble.midX - w * 0.21, y: y, width: w * len, height: w * 0.045), xRadius: w * 0.0225, yRadius: w * 0.0225).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
