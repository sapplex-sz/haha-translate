import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let destination = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Bitmap creation failed") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size) / 1024); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.48, blue: 0.25, alpha: 1), ending: NSColor(srgbRed: 0.87, green: 0.22, blue: 0.105, alpha: 1))!.draw(in: tile, angle: -80)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -15); shadow.set()
    NSColor.white.setFill()
    let bubble = NSBezierPath(roundedRect: NSRect(x: 184, y: 285, width: 656, height: 475), xRadius: 147, yRadius: 147)
    bubble.fill()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 312, y: 320)); tail.line(to: NSPoint(x: 288, y: 192)); tail.curve(to: NSPoint(x: 500, y: 320), controlPoint1: NSPoint(x: 328, y: 190), controlPoint2: NSPoint(x: 450, y: 275)); tail.close(); tail.fill()
    NSGraphicsContext.restoreGraphicsState()
    let orange = NSColor(srgbRed: 0.91, green: 0.32, blue: 0.16, alpha: 1); orange.setFill(); orange.setStroke()
    NSBezierPath(roundedRect: NSRect(x: 356, y: 533, width: 54, height: 104), xRadius: 27, yRadius: 27).fill()
    NSBezierPath(roundedRect: NSRect(x: 614, y: 533, width: 54, height: 104), xRadius: 27, yRadius: 27).fill()
    let smile = NSBezierPath(); smile.lineWidth = 38; smile.lineCapStyle = .round
    smile.move(to: NSPoint(x: 369, y: 447)); smile.curve(to: NSPoint(x: 655, y: 447), controlPoint1: NSPoint(x: 450, y: 351), controlPoint2: NSPoint(x: 574, y: 351)); smile.stroke()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG generation failed") }
    return png
}

var entries: [[String: String]] = []
for logical in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = logical * scale
        let name = "icon_\(logical)x\(logical)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(size: size).write(to: destination.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(logical)x\(logical)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: destination.deletingLastPathComponent().appendingPathComponent("Contents.json"))
let brand = destination.deletingLastPathComponent().appendingPathComponent("BrandMark.imageset")
try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
try drawIcon(size: 256).write(to: brand.appendingPathComponent("brand.png"))
try Data("{\"images\":[{\"filename\":\"brand.png\",\"idiom\":\"universal\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: brand.appendingPathComponent("Contents.json"))
print("Generated native vector app icon.")
