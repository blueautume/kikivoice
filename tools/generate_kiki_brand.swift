// Regenerate the app icons and scalable launch mark with: swift tools/generate_kiki_brand.swift
// The original artwork is defined below as vector paths; no external artwork is required.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let assetRoot = repositoryRoot.appendingPathComponent("ios/KikiTalk/Resources/Assets.xcassets")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

enum Appearance { case standard, dark, tinted }

func drawBrand(in context: CGContext, appearance: Appearance, launchTile: Bool = false) {
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    if launchTile {
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                               cornerWidth: 232, cornerHeight: 232, transform: nil))
        context.clip()
    }
    let shades: [UInt32]
    switch appearance {
    case .standard: shades = [0xA27DFF, 0x7950ED, 0x5426C6]
    case .dark: shades = [0x3E285F, 0x25183F, 0x171022]
    case .tinted: shades = [0x545454, 0x3A3A3A, 0x252525]
    }
    let gradient = CGGradient(colorsSpace: colorSpace, colors: shades.map { color($0) } as CFArray,
                              locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 80, y: 60), end: CGPoint(x: 930, y: 1024),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // PDF shading cannot preserve gradient alpha on every iOS renderer. Keep the
    // scalable launch tile opaque; the bitmap icons can include the soft glow.
    if !launchTile {
        let glow = CGGradient(colorsSpace: colorSpace,
                              colors: [color(0xFFFFFF, alpha: appearance == .dark ? 0.07 : 0.13),
                                       color(0xFFFFFF, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 150, y: 90), startRadius: 0,
                                  endCenter: CGPoint(x: 150, y: 90), endRadius: 900, options: [])
    }

    context.translateBy(x: 0, y: -12)
    let ink = appearance == .dark ? color(0xEDE5FF) : color(0xFFFFFF)
    let bubble = CGMutablePath()
    bubble.move(to: CGPoint(x: 340, y: 238))
    bubble.addLine(to: CGPoint(x: 684, y: 238))
    bubble.addCurve(to: CGPoint(x: 824, y: 378), control1: CGPoint(x: 762, y: 238), control2: CGPoint(x: 824, y: 300))
    bubble.addLine(to: CGPoint(x: 824, y: 594))
    bubble.addCurve(to: CGPoint(x: 684, y: 734), control1: CGPoint(x: 824, y: 672), control2: CGPoint(x: 762, y: 734))
    bubble.addLine(to: CGPoint(x: 466, y: 734))
    bubble.addLine(to: CGPoint(x: 302, y: 834))
    bubble.addLine(to: CGPoint(x: 324, y: 724))
    bubble.addCurve(to: CGPoint(x: 200, y: 594), control1: CGPoint(x: 249, y: 715), control2: CGPoint(x: 200, y: 663))
    bubble.addLine(to: CGPoint(x: 200, y: 378))
    bubble.addCurve(to: CGPoint(x: 340, y: 238), control1: CGPoint(x: 200, y: 300), control2: CGPoint(x: 262, y: 238))
    bubble.closeSubpath()
    context.addPath(bubble)
    context.setStrokeColor(ink)
    context.setLineWidth(44)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
    context.setFillColor(ink)
    for (index, height) in [130.0, 230, 316, 230, 130].enumerated() {
        context.addPath(CGPath(roundedRect: CGRect(x: 354 + Double(index) * 68, y: 486 - height / 2,
                                                  width: 44, height: height),
                               cornerWidth: 22, cornerHeight: 22, transform: nil))
        context.fillPath()
    }
}

func writeIcon(_ name: String, appearance: Appearance) throws {
    // Opaque sRGB is required for the App Store icon, including appearance variants.
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                            bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setAllowsAntialiasing(true)
    drawBrand(in: context, appearance: appearance)
    let target = assetRoot.appendingPathComponent("KikiAppIcon.appiconset/\(name)")
    let output = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
}

try writeIcon("Icon.png", appearance: .standard)
try writeIcon("IconDark.png", appearance: .dark)
try writeIcon("IconTinted.png", appearance: .tinted)
let markDirectory = assetRoot.appendingPathComponent("KikiLaunchMark.imageset")
try FileManager.default.createDirectory(at: markDirectory, withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 128, height: 128)
let consumer = CGDataConsumer(url: markDirectory.appendingPathComponent("KikiLaunchMark.pdf") as CFURL)!
let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.scaleBy(x: 0.125, y: 0.125)
drawBrand(in: pdf, appearance: .standard, launchTile: true)
pdf.endPDFPage()
pdf.closePDF()
print("Generated three 1024px app icons and a scalable launch mark.")
