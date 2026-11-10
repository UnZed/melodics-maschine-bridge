import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let unit = CGFloat(pixels) / 1024
    context.scaleBy(x: unit, y: unit)
    context.setFillColor(red: 1, green: 202.0 / 255, blue: 0, alpha: 1)
    NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840),
                 xRadius: 184, yRadius: 184).fill()
    for row in 0..<4 {
        for column in 0..<4 {
            let isAccent = row == 0 && column == 0
            context.setFillColor(red: 0.08, green: isAccent ? 0.43 : 0.10,
                                 blue: isAccent ? 0.69 : 0.11, alpha: 1)
            let rect = NSRect(x: 264 + column * 128, y: 264 + row * 128, width: 112, height: 112)
            NSBezierPath(roundedRect: rect, xRadius: 19, yRadius: 19).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(
        to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
    )
}
