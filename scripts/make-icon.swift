#!/usr/bin/env swift
// Renders the MeetingNotes app icon and packs it into Assets/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
//
// Design: macOS icon grid (824pt squircle body on a 1024 canvas) in the app's
// Theme.primaryBlue, with a notes card showing a live waveform, transcript
// lines and a recording dot.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func render() -> CGImage {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Origin bottom-left.

    // Body: 824×824 squircle with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x387BF6)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    linear(ctx, [rgb(0x5B95FF), rgb(0x387BF6), rgb(0x2457D6)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Subtle top sheen.
    linear(ctx, [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 640))
    ctx.restoreGState()

    // Notes card.
    let card = CGRect(x: 262, y: 214, width: 500, height: 590)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x0B2A7A, 0.35))
    ctx.addPath(cardPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(cardPath); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xEEF3FC)], from: CGPoint(x: 512, y: card.maxY), to: CGPoint(x: 512, y: card.minY))
    ctx.restoreGState()

    // Waveform (blue → purple), centred in the top part of the card.
    let heights: [CGFloat] = [56, 112, 176, 228, 160, 100, 52]
    let barW: CGFloat = 34, gap: CGFloat = 20
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    let midY: CGFloat = 652
    var x = card.midX - totalW / 2
    ctx.saveGState()
    for h in heights {
        let r = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        x += barW + gap
    }
    ctx.clip()
    linear(ctx, [rgb(0x387BF6), rgb(0xAE61E0)],
           from: CGPoint(x: card.midX - totalW / 2, y: midY), to: CGPoint(x: card.midX + totalW / 2, y: midY))
    ctx.restoreGState()

    // Transcript / notes lines.
    let lines: [(CGFloat, CGColor)] = [
        (380, rgb(0xC9D3E6)), (380, rgb(0xC9D3E6)), (300, rgb(0xC9D3E6)), (200, rgb(0x387BF6, 0.55)),
    ]
    var ly: CGFloat = 490
    for (w, c) in lines {
        let r = CGRect(x: card.minX + 60, y: ly, width: w, height: 28)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(c); ctx.fillPath()
        ly -= 66
    }

    // Recording dot on the card's top-right corner.
    let dot = CGPoint(x: card.maxX - 6, y: card.maxY - 6)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x7A0A14, 0.35))
    ctx.addEllipse(in: CGRect(x: dot.x - 70, y: dot.y - 70, width: 140, height: 140))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: dot.x - 52, y: dot.y - 52, width: 104, height: 104)); ctx.clip()
    linear(ctx, [rgb(0xFF6B74), rgb(0xF04754), rgb(0xD12F3C)],
           from: CGPoint(x: dot.x, y: dot.y + 52), to: CGPoint(x: dot.x, y: dot.y - 52))
    ctx.restoreGState()

    return ctx.makeImage()!
}

func scaled(_ img: CGImage, to px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = render()
writePNG(master, assets.appendingPathComponent("AppIcon-1024.png"))
for pt in [16, 32, 128, 256, 512] {
    writePNG(scaled(master, to: pt), iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(scaled(master, to: pt * 2), iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
try? FileManager.default.removeItem(at: iconset)
print("Wrote Assets/AppIcon.icns and Assets/AppIcon-1024.png")
