#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate-icon.swift <iconset-directory>")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    let size = CGFloat(variant.pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let inset = size * 0.06
    let iconRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: iconRect, xRadius: size * 0.22, yRadius: size * 0.22)
    NSGradient(
        starting: NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.24, alpha: 1),
        ending: NSColor(calibratedRed: 0.20, green: 0.34, blue: 0.62, alpha: 1)
    )?.draw(in: shape, angle: -50)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.57, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: -size * 0.045
    ]
    let mark = NSAttributedString(string: "m", attributes: attributes)
    mark.draw(in: NSRect(x: 0, y: size * 0.19, width: size, height: size * 0.64))

    let lineWidth = max(1, size * 0.025)
    NSColor(calibratedRed: 0.47, green: 0.83, blue: 1, alpha: 0.9).setStroke()
    for offset in [0.0, 0.055, 0.11] {
        let line = NSBezierPath()
        line.lineWidth = lineWidth
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: size * 0.35, y: size * (0.19 - offset)))
        line.line(to: NSPoint(x: size * 0.65, y: size * (0.19 - offset)))
        line.stroke()
    }

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(variant.name)")
    }
    try png.write(to: outputDirectory.appendingPathComponent(variant.name), options: .atomic)
}
