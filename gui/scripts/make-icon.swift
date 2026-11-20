// Renders the app icon SVG (default gui/icons/a3b-lcd-clay.svg) into a full .iconset,
// adding the standard macOS icon shadow under the squircle.
// Usage: swift scripts/make-icon.swift <output.iconset> [icon.svg]
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: args.first ?? "AppIcon.iconset")
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let svg = args.count > 1 ? URL(fileURLWithPath: args[1])
    : scriptDir.appendingPathComponent("../icons/a3b-lcd-clay.svg").standardizedFileURL
guard let icon = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write("make-icon: cannot read \(svg.path)\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let s = size / 1024
    // The SVG body already sits on the macOS grid (824 squircle at 100,100), so draw it full-frame;
    // the shadow is cast by the squircle's own alpha.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
