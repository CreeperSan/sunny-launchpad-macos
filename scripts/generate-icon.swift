// 程序绘制可维护的太阳网格图标，不依赖外部图片或商标素材。
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 1, green: 0.83, blue: 0.30, alpha: 1), ending: NSColor(calibratedRed: 1, green: 0.43, blue: 0.16, alpha: 1))!.draw(in: tile, angle: -70)
        NSColor.white.withAlphaComponent(0.9).setFill()
        let cell: CGFloat = 142
        let gap: CGFloat = 45
        let origin: CGFloat = 254
        for row in 0..<3 {
            for column in 0..<3 {
                let rect = NSRect(x: origin + CGFloat(column) * (cell + gap), y: origin + CGFloat(row) * (cell + gap), width: cell, height: cell)
                NSBezierPath(roundedRect: rect, xRadius: 37, yRadius: 37).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
