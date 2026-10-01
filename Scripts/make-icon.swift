import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs("Usage: make-icon.swift input.svg output.iconset output.icns\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[3])
let fileManager = FileManager.default

guard let source = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to load SVG\n", stderr)
    exit(3)
}

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, pixels) in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { exit(4) }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(5) }
    try png.write(to: iconsetURL.appending(path: name), options: .atomic)
}

func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return Data(bytes: &number, count: MemoryLayout<UInt32>.size)
}

let chunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]
var body = Data()
for (type, filename) in chunks {
    let png = try Data(contentsOf: iconsetURL.appending(path: filename))
    body.append(type.data(using: .ascii)!)
    body.append(bigEndian(UInt32(png.count + 8)))
    body.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(body.count + 8)))
icns.append(body)
try icns.write(to: outputURL, options: .atomic)
