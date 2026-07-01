#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate-icon.swift <output.icns>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
let iconsetURL = outputURL
    .deletingPathExtension()
    .appendingPathExtension("iconset")

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try fileManager.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let iconSizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

for iconSize in iconSizes {
    let pixels = Int(iconSize.points * iconSize.scale)
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("failed to render \(iconSize.name)\n", stderr)
        exit(65)
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(iconSize.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

try? fileManager.removeItem(at: iconsetURL)

if process.terminationStatus != 0 {
    exit(process.terminationStatus)
}

private func drawIcon(in rect: CGRect) {
    let bounds = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
    let radius = rect.width * 0.22
    let backgroundPath = NSBezierPath(
        roundedRect: bounds,
        xRadius: radius,
        yRadius: radius
    )

    let backgroundGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.14, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.25, alpha: 1)
    ])
    backgroundGradient?.draw(in: backgroundPath, angle: 90)

    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
    backgroundPath.lineWidth = max(1, rect.width * 0.008)
    backgroundPath.stroke()

    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ringRadius = rect.width * 0.28
    let ringRect = CGRect(
        x: center.x - ringRadius,
        y: center.y - ringRadius,
        width: ringRadius * 2,
        height: ringRadius * 2
    )
    let ringPath = NSBezierPath(ovalIn: ringRect)
    NSColor(calibratedRed: 0.38, green: 0.86, blue: 0.78, alpha: 1).setStroke()
    ringPath.lineWidth = rect.width * 0.045
    ringPath.stroke()

    let recordRadius = rect.width * 0.115
    let recordPath = NSBezierPath(
        ovalIn: CGRect(
            x: center.x - recordRadius,
            y: center.y - recordRadius,
            width: recordRadius * 2,
            height: recordRadius * 2
        )
    )
    NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.27, alpha: 1).setFill()
    recordPath.fill()

    drawWave(
        center: CGPoint(x: rect.midX, y: rect.midY),
        width: rect.width * 0.66,
        height: rect.height * 0.22,
        lineWidth: rect.width * 0.035
    )
}

private func drawWave(center: CGPoint, width: CGFloat, height: CGFloat, lineWidth: CGFloat) {
    let path = NSBezierPath()
    let segments = 72
    let startX = center.x - width / 2

    for index in 0...segments {
        let progress = CGFloat(index) / CGFloat(segments)
        let x = startX + width * progress
        let wave = sin(progress * CGFloat.pi * 4)
        let y = center.y + wave * height * 0.5

        if index == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.line(to: CGPoint(x: x, y: y))
        }
    }

    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = lineWidth
    NSColor(calibratedWhite: 1, alpha: 0.92).setStroke()
    path.stroke()
}
