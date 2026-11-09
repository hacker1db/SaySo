// Renders Resources/Sayso.icns: dark tile with an ember microphone and a text caret.
import AppKit
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    // Dark ink tile with an ember microphone; a cream text caret beside it marks "speech becomes text".
    let tile = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(starting: NSColor(red: 0.17, green: 0.15, blue: 0.20, alpha: 1), ending: NSColor(red: 0.09, green: 0.08, blue: 0.11, alpha: 1))!
        .draw(in: tile, angle: -90)
    let w = box.width, cx = box.midX - w * 0.06
    let ember = NSGradient(starting: NSColor(red: 0.98, green: 0.78, blue: 0.52, alpha: 1), ending: NSColor(red: 0.94, green: 0.54, blue: 0.36, alpha: 1))!
    // Capsule head
    let headW = w * 0.24, headH = w * 0.38
    let head = NSRect(x: cx - headW / 2, y: box.minY + w * 0.42, width: headW, height: headH)
    ember.draw(in: NSBezierPath(roundedRect: head, xRadius: headW / 2, yRadius: headW / 2), angle: -90)
    // Grille lines
    NSColor(red: 0.12, green: 0.11, blue: 0.14, alpha: 0.35).setFill()
    for i in 0..<3 {
        let y = head.maxY - headW * 0.55 - CGFloat(i) * w * 0.06
        NSBezierPath(roundedRect: NSRect(x: head.minX + headW * 0.28, y: y, width: headW * 0.44, height: w * 0.022), xRadius: w * 0.011, yRadius: w * 0.011).fill()
    }
    // Cradle arc, stem and base
    let stroke = w * 0.045
    NSColor(red: 0.95, green: 0.62, blue: 0.40, alpha: 1).setStroke()
    let arc = NSBezierPath()
    let r = headW * 0.85, arcCenter = NSPoint(x: cx, y: head.minY + headW * 0.62)
    arc.appendArc(withCenter: arcCenter, radius: r, startAngle: 200, endAngle: 340, clockwise: false)
    arc.lineWidth = stroke; arc.lineCapStyle = .round; arc.stroke()
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: cx, y: arcCenter.y - r)); stem.line(to: NSPoint(x: cx, y: box.minY + w * 0.19))
    stem.move(to: NSPoint(x: cx - w * 0.1, y: box.minY + w * 0.19)); stem.line(to: NSPoint(x: cx + w * 0.1, y: box.minY + w * 0.19))
    stem.lineWidth = stroke; stem.lineCapStyle = .round; stem.stroke()
    // Text caret
    NSColor(red: 0.96, green: 0.94, blue: 0.91, alpha: 1).setFill()
    let caretW = w * 0.05, caretH = w * 0.30
    NSBezierPath(roundedRect: NSRect(x: cx + w * 0.27, y: head.midY - caretH / 2, width: caretW, height: caretH), xRadius: caretW / 2, yRadius: caretW / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
