import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: make-icon.swift <source.png> <output.iconset> <menu-bar.png>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let menuBarURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height, artwork.width >= 1024 else {
    fatalError("The source icon must be square and at least 1024 pixels wide.")
}

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not open \(url.lastPathComponent) for writing.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.lastPathComponent).") }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size * scale
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            fatalError("Could not resize the app icon to \(size * scale) pixels.")
        }
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        writePNG(image, to: iconset.appendingPathComponent(filename))
    }
}

// Keep the light geometry from the centre of the artwork as a status-item template.
let inset = artwork.width * 21 / 100
let markWidth = artwork.width - inset * 2
let markBounds = CGRect(x: inset, y: inset, width: markWidth, height: markWidth)
let templateSize = 72
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
guard let mark = artwork.cropping(to: markBounds),
      let bitmap = CGContext(data: nil, width: templateSize, height: templateSize, bitsPerComponent: 8,
                             bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo),
      let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Could not prepare the menu bar template.")
}
bitmap.interpolationQuality = .high
bitmap.draw(mark, in: CGRect(x: 0, y: 0, width: templateSize, height: templateSize))

for row in 0..<templateSize {
    for column in 0..<templateSize {
        let pixel = bytes.advanced(by: row * bitmap.bytesPerRow + column * 4)
        // Separate the white mark from the black tile while preserving antialiased edges.
        let luminance = (54 * Int(pixel[0]) + 183 * Int(pixel[1]) + 19 * Int(pixel[2])) / 256
        let opacity = UInt8(clamping: (luminance - 80) * 255 / 135)
        pixel[0] = 0
        pixel[1] = 0
        pixel[2] = 0
        pixel[3] = opacity
    }
}

guard let template = bitmap.makeImage() else { fatalError("Could not render the menu bar template.") }
writePNG(template, to: menuBarURL)
