// Draws the app icon and writes Resources/AppIcon.icns (for the app) and docs/icon.png
// (512 px, for the README). Both are committed, so building doesn't need this. Run it from the
// top folder after changing the drawing, then look at docs/icon.png and at the small sizes,
// which have to read at 32 px:
//
//   swift scripts/make_icon.swift
//   iconutil -c iconset Resources/AppIcon.icns -o /tmp/AppIcon.iconset
//
// It follows Apple's macOS icon grid: a 1024 px canvas with an 824 px rounded square in the
// middle, continuous corners and a soft shadow in the transparent margin.

import AppKit
import SwiftUI

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let canvas: CGFloat = 1024

func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

/// A rounded rectangle with Apple's continuous corners, as the system draws icons and windows.
func continuous(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
}

/// Draws with a drop shadow given in canvas pixels. A shadow ignores the context's scale and is
/// measured in output pixels, so `scale` (output pixels per canvas pixel) sizes it to match.
func withShadow(_ offsetY: CGFloat, blur: CGFloat, alpha: CGFloat, scale: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: offsetY * scale)
    shadow.shadowBlurRadius = blur * scale
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws the icon on the 1024 px canvas, with the origin at the bottom left, into a context
/// scaled by `scale` to the output size.
func drawIcon(scale: CGFloat) {
    // The tile: a calm blue to indigo gradient.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = continuous(tileRect, radius: 185)
    withShadow(-12, blur: 28, alpha: 0.32, scale: scale) {
        colour(80, 110, 230).setFill()
        tile.fill()
    }
    NSGradient(colors: [colour(84, 156, 248), colour(76, 104, 232), colour(92, 72, 210)])?
        .draw(in: tile, angle: -90)
    // A faint light from the top, so the tile doesn't look flat.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])?
        .draw(in: tile, relativeCenterPosition: NSPoint(x: 0, y: 1))

    // The window card, floating slightly raised.
    let cardRect = CGRect(x: 222, y: 250, width: 580, height: 440)
    let card = continuous(cardRect, radius: 52)
    withShadow(-18, blur: 40, alpha: 0.30, scale: scale) {
        colour(246, 248, 255).setFill()
        card.fill()
    }
    // Its title bar and the three window buttons.
    NSGraphicsContext.saveGraphicsState()
    card.addClip()
    colour(222, 228, 245).setFill()
    CGRect(x: cardRect.minX, y: cardRect.maxY - 84, width: cardRect.width, height: 84).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (index, fill) in [colour(255, 95, 87), colour(254, 188, 46), colour(40, 200, 64)].enumerated() {
        fill.setFill()
        let x = cardRect.minX + 52 + CGFloat(index) * 46
        NSBezierPath(ovalIn: CGRect(x: x - 15, y: cardRect.maxY - 42 - 15, width: 30, height: 30)).fill()
    }
    // A few lines of content.
    colour(208, 214, 234).setFill()
    for (index, width) in [CGFloat(380), 440, 300].enumerated() {
        let y = cardRect.maxY - 160 - CGFloat(index) * 70
        continuous(CGRect(x: cardRect.minX + 56, y: y, width: width, height: 30), radius: 15).fill()
    }

    // The pin, pressed into the card's top right corner.
    let configuration = NSImage.SymbolConfiguration(pointSize: 300, weight: .regular)
        .applying(.init(paletteColors: [colour(255, 69, 58)]))
    guard let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else { fatalError("The pin.fill symbol isn't available") }
    let pinSize = pin.size
    withShadow(-14, blur: 22, alpha: 0.35, scale: scale) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 700, yBy: 640)
        transform.rotate(byDegrees: -35)
        transform.concat()
        pin.draw(in: CGRect(x: -pinSize.width / 2, y: -pinSize.height / 2, width: pinSize.width, height: pinSize.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The icon as a PNG, drawn afresh at this many pixels square so small sizes stay sharp.
func png(pixels: Int) -> Data {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Couldn't make a \(pixels) px drawing context") }
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    drawIcon(scale: scale)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("Couldn't make the \(pixels) px PNG") }
    return data
}

func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

MainActor.assumeIsolated {
    do {
        let files = FileManager.default
        let iconset = files.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
        defer { try? files.removeItem(at: iconset) }

        // The sizes an .icns holds, each at 1x and 2x.
        for size in [16, 32, 128, 256, 512] {
            try write(png(pixels: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try write(png(pixels: size * 2), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        try write(png(pixels: 512), to: root.appendingPathComponent("docs/icon.png"))

        let icns = root.appendingPathComponent("Resources/AppIcon.icns")
        try files.createDirectory(at: icns.deletingLastPathComponent(), withIntermediateDirectories: true)
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
        print("Wrote Resources/AppIcon.icns and docs/icon.png")
    } catch {
        fatalError("Couldn't write the icon: \(error.localizedDescription)")
    }
}
