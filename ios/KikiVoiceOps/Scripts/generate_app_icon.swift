#!/usr/bin/env swift
import AppKit

// Vector geometry is the source of truth; all variants use opaque sRGB pixels.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

struct Palette {
    let name: String
    let background: [CGColor]
    let panel: CGColor
    let waveform: CGColor
    let heading: CGColor
    let status: CGColor
    let appearance: String?
}

let palettes = [
    Palette(name: "AppIcon", background: [color(77, 43, 186), color(141, 87, 249)],
            panel: color(255, 255, 255), waveform: color(111, 68, 226),
            heading: color(219, 208, 250), status: color(54, 204, 158), appearance: nil),
    Palette(name: "AppIcon-Dark", background: [color(18, 15, 38), color(47, 29, 88)],
            panel: color(65, 47, 109), waveform: color(225, 211, 255),
            heading: color(143, 116, 196), status: color(88, 231, 180), appearance: "dark"),
    Palette(name: "AppIcon-Tinted", background: [color(20, 20, 20), color(44, 44, 44)],
            panel: color(235, 235, 235), waveform: color(42, 42, 42),
            heading: color(153, 153, 153), status: color(105, 105, 105), appearance: "tinted")
]

func rounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor) {
    context.setFillColor(fill)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.fillPath()
}

try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var images: [[String: Any]] = []
for palette in palettes {
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                            bytesPerRow: 1024 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let gradient = CGGradient(colorsSpace: context.colorSpace,
                              colors: palette.background as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 96, y: 0),
                               end: CGPoint(x: 928, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    context.saveGState()
    let shadow = palette.appearance == "tinted" ? color(0, 0, 0, 0.18) : color(23, 7, 71, 0.18)
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 42, color: shadow)
    rounded(context, CGRect(x: 226, y: 226, width: 572, height: 572), radius: 132, fill: palette.panel)
    context.restoreGState()

    rounded(context, CGRect(x: 320, y: 696, width: 156, height: 24), radius: 12, fill: palette.heading)
    context.setFillColor(palette.status)
    context.fillEllipse(in: CGRect(x: 674, y: 684, width: 48, height: 48))

    let heights: [CGFloat] = [112, 208, 320, 208, 112]
    for (index, height) in heights.enumerated() {
        rounded(context, CGRect(x: 328 + CGFloat(index) * 80, y: 480 - height / 2,
                                width: 48, height: height), radius: 24, fill: palette.waveform)
    }

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    guard let data = bitmap.representation(using: .png, properties: [:]), !bitmap.hasAlpha else {
        fatalError("App icons must be opaque PNG images")
    }
    try data.write(to: destination.appendingPathComponent(palette.name + ".png"), options: .atomic)
    var entry: [String: Any] = ["filename": palette.name + ".png", "idiom": "universal",
                                "platform": "ios", "size": "1024x1024"]
    if let appearance = palette.appearance {
        entry["appearances"] = [["appearance": "luminosity", "value": appearance]]
    }
    images.append(entry)
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let metadata = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try metadata.write(to: destination.appendingPathComponent("Contents.json"), options: .atomic)
print("Generated 3 opaque 1024×1024 KikiVoiceOps app icons.")
