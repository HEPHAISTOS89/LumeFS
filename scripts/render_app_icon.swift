// Reproducible, original geometric artwork. No source image or generative model.
// Run from the repository root: swift scripts/render_app_icon.swift
import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
let sizes = [16, 32, 128, 256, 512]

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    NSColor(red: 0.08, green: 0.16, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                 xRadius: 192, yRadius: 192).fill()

    // Three storage trays: a single recognizable silhouette at small sizes.
    let ink = NSColor(red: 0.92, green: 0.95, blue: 0.97, alpha: 1)
    for y in [274, 442, 610] {
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: y, width: 536, height: 140),
                     xRadius: 36, yRadius: 36).fill()
        NSColor(red: 0.08, green: 0.16, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 298, y: y + 58, width: 230, height: 24),
                     xRadius: 12, yRadius: 12).fill()
        NSColor(red: 0.0, green: 0.39, blue: 0.77, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 660, y: y + 46, width: 48, height: 48)).fill()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for size in sizes {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let filename = "icon_\(size)x\(size)\(suffix).png"
        try drawIcon(size: size * scale).write(to: outputDirectory.appendingPathComponent(filename))
    }
}
print("Rendered 10 app icon sizes from geometric paths.")
