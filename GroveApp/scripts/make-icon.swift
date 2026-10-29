#!/usr/bin/env swift
//
// Draws Grove.icns.
//
//   ./scripts/make-icon.swift            # regenerates Resources/Grove.icns
//
// The icon is generated rather than checked in as an opaque binary so it can be
// reviewed and adjusted in a diff like everything else.
//
// Design constraints, in order:
//  - Legible at 16pt. That rules out anything finely detailed; the mark is four
//    bars and nothing else.
//  - Reads as audio, not as a document. Grove listens; the notes are downstream.
//  - Warm oat colours rather than the blue every Mac utility defaults to, so it
//    is findable in a crowded Dock.
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(size: Int) -> NSBitmapImageRep {
    let dimension = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS app icons sit in a rounded square inset from the canvas, so the
    // system's own shadow and grid alignment have room to work.
    let inset = dimension * 0.055
    let rect = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = rect.width * 0.2237  // Apple's continuous-corner ratio.
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    context.saveGState()
    squircle.addClip()
    let background = NSGradient(colors: [
        NSColor(srgbRed: 0.99, green: 0.93, blue: 0.79, alpha: 1),  // oat cream
        NSColor(srgbRed: 0.91, green: 0.74, blue: 0.40, alpha: 1),  // toasted amber
    ])!
    background.draw(in: rect, angle: -90)
    context.restoreGState()

    // Waveform: four bars, tallest in the middle, so it reads as speech rather
    // than as a bar chart. Heights are fractions of the icon, not of each other,
    // so they stay proportional at every size.
    let ink = NSColor(srgbRed: 0.26, green: 0.17, blue: 0.08, alpha: 1)
    ink.setFill()

    let heights: [CGFloat] = [0.30, 0.52, 0.40, 0.20]
    let barWidth = rect.width * 0.088
    let gap = rect.width * 0.072
    let totalWidth = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x = rect.midX - totalWidth / 2

    for height in heights {
        let barHeight = rect.height * height
        let bar = CGRect(
            x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Grove.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil wants specific @1x/@2x pairs; anything missing makes it fail loudly.
let names: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

var cache: [Int: Data] = [:]
for size in sizes {
    cache[size] = draw(size: size).representation(using: .png, properties: [:])!
}
for (size, name) in names {
    try cache[size]!.write(to: iconset.appendingPathComponent(name))
}

let icns = root.appendingPathComponent("Resources/Grove.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote \(icns.path)")
