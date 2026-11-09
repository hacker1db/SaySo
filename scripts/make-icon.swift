// Renders Resources/Sayso.icns: ember-to-honey squircle with white voice bars.
import AppKit
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(starting: NSColor(red: 0.94, green: 0.54, blue: 0.36, alpha: 1), ending: NSColor(red: 0.98, green: 0.78, blue: 0.52, alpha: 1))!
        .draw(in: shape, angle: 70)
    NSColor.white.setFill()
    let heights: [CGFloat] = [0.22, 0.42, 0.62, 0.42, 0.22], bar = box.width * 0.085, gap = box.width * 0.06
    var x = box.midX - (CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap) / 2
    for h in heights {
        let height = box.height * h
        NSBezierPath(roundedRect: NSRect(x: x, y: box.midY - height / 2, width: bar, height: height), xRadius: bar / 2, yRadius: bar / 2).fill()
        x += bar + gap
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
