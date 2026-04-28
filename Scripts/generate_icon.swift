#!/usr/bin/env swift
// Generates MusicTagger/Resources/AppIcon.icns
//
// Usage: swift Scripts/generate_icon.swift
//
// Draws a rounded-square gradient with a white music-note glyph at every
// required iconset size, then runs `iconutil` to bundle them into a .icns.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Drawing

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size, height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("ctx") }

    // macOS Big Sur+ icon: ~824/1024 squircle inside the canvas.
    let inset: CGFloat = s * 0.0977
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius: CGFloat = (s - 2 * inset) * 0.2237

    // Soft outer shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.025,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [
        CGColor(red: 0.18, green: 0.32, blue: 0.84, alpha: 1.0),  // deep blue
        CGColor(red: 0.62, green: 0.24, blue: 0.93, alpha: 1.0),  // violet
    ] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end:   CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // Subtle top highlight.
    let hi = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray
    let highlight = CGGradient(colorsSpace: cs, colors: hi, locations: [0, 1])!
    ctx.drawLinearGradient(highlight,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end:   CGPoint(x: rect.midX, y: rect.midY),
                           options: [])
    ctx.restoreGState()

    // Music note glyph (♫) drawn in white.
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    let glyph = "\u{266B}"  // ♫
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.62, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: glyph, attributes: attrs)
    let strSize = str.size()
    let drawRect = CGRect(
        x: (s - strSize.width) / 2,
        y: (s - strSize.height) / 2 - s * 0.03,
        width: strSize.width,
        height: strSize.height
    )
    str.draw(in: drawRect)

    NSGraphicsContext.restoreGraphicsState()

    let cgImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Iconset assembly

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("MusicTagger/Resources")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// (filename, pixel size)
let entries: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in entries {
    let data = renderIcon(size: size)
    try data.write(to: iconsetDir.appendingPathComponent(name))
    print("wrote \(name) (\(size)x\(size))")
}

// Run iconutil to produce the .icns.
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", "-o", icnsURL.path, iconsetDir.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(proc.terminationStatus)\n".data(using: .utf8)!)
    exit(Int32(proc.terminationStatus))
}

// Clean up the intermediate iconset folder; keep just the .icns.
try? FileManager.default.removeItem(at: iconsetDir)

print("✓ \(icnsURL.path)")
