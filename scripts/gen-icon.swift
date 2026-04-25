// Generates a 1024x1024 PNG app icon by rendering the 🐾 emoji on a
// rounded dark gradient background. Usage:
//   swift scripts/gen-icon.swift <output.png>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count >= 2
    ? CommandLine.arguments[1]
    : "/tmp/cli-buddy-icon.png"

let size: CGFloat = 1024
let cornerRadius: CGFloat = 180  // macOS Big Sur+ mask radius is ~22.37% of size
let emoji = "🐾"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let bgRect = NSRect(x: 0, y: 0, width: size, height: size)
let clipPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
clipPath.addClip()

// Jade / teal gradient — light top to deeper bottom — tuned for
// contrast against both light and dark macOS docks.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.37, green: 0.92, blue: 0.83, alpha: 1), // #5EEAD4 top
    NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.53, alpha: 1), // #0D9488 bottom
])
gradient?.draw(in: bgRect, angle: -90)

// Soft inner top highlight so the tile reads like a glossy macOS icon.
let highlight = NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.22),
    NSColor(calibratedWhite: 1, alpha: 0.0),
])
highlight?.draw(in: NSRect(x: 0, y: size * 0.55, width: size, height: size * 0.45), angle: -90)

// Center the emoji. systemFont at this size lets macOS swap in Apple
// Color Emoji so we get the full-color paw print.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size * 0.60),
    .paragraphStyle: paragraph,
]
let attrStr = NSAttributedString(string: emoji, attributes: attrs)
let strSize = attrStr.size()
// Visual centering — emoji glyphs have built-in asymmetric bearings,
// so we nudge up slightly.
let strRect = NSRect(
    x: (size - strSize.width) / 2,
    y: (size - strSize.height) / 2 - size * 0.04,
    width: strSize.width,
    height: strSize.height
)
attrStr.draw(in: strRect)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("failed to encode png\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath)")
