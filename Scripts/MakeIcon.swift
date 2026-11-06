import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(size) / 1024)
        transform.concat()
        let bg = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 204, yRadius: 204)
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill(); bg.fill()
        NSColor(srgbRed: 1, green: 0.68, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 200,y: 240,width: 624,height: 544),xRadius: 90,yRadius: 90).fill()
        NSColor(srgbRed: 0.12,green: 0.13,blue: 0.15,alpha: 1).setFill()
        for y in [370.0,500.0,630.0] {
            NSBezierPath(roundedRect:NSRect(x:290,y:y,width:70,height:60),xRadius:18,yRadius:18).fill()
            NSBezierPath(roundedRect:NSRect(x:400,y:y+8,width:320,height:44),xRadius:16,yRadius:16).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
