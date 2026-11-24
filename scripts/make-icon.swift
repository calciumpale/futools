import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func icon(size: Int) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGPath(roundedRect: CGRect(x: 89, y: 94, width: 846, height: 846),
                      cornerWidth: 194, cornerHeight: 194, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -16), blur: 38,
                color: CGColor(gray: 0, alpha: 0.29))
    c.addPath(tile)
    c.setFillColor(color(0x183A2C))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tile)
    c.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [color(0x30684D), color(0x133025)] as CFArray,
                              locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 905),
                         end: CGPoint(x: 900, y: 150), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    let bubble = CGMutablePath()
    bubble.move(to: CGPoint(x: 338, y: 314))
    bubble.addQuadCurve(to: CGPoint(x: 258, y: 396), control: CGPoint(x: 258, y: 322))
    bubble.addLine(to: CGPoint(x: 258, y: 624))
    bubble.addQuadCurve(to: CGPoint(x: 344, y: 710), control: CGPoint(x: 258, y: 710))
    bubble.addLine(to: CGPoint(x: 680, y: 710))
    bubble.addQuadCurve(to: CGPoint(x: 766, y: 624), control: CGPoint(x: 766, y: 710))
    bubble.addLine(to: CGPoint(x: 766, y: 396))
    bubble.addQuadCurve(to: CGPoint(x: 680, y: 310), control: CGPoint(x: 766, y: 310))
    bubble.addLine(to: CGPoint(x: 446, y: 310))
    bubble.addLine(to: CGPoint(x: 338, y: 251))
    bubble.closeSubpath()
    c.addPath(bubble)
    c.setStrokeColor(color(0xE5F4E7))
    c.setLineWidth(35)
    c.setLineJoin(.round)
    c.setLineCap(.round)
    c.strokePath()

    c.setStrokeColor(color(0xB6EDC4))
    c.setLineWidth(38)
    c.move(to: CGPoint(x: 383, y: 573))
    c.addLine(to: CGPoint(x: 446, y: 514))
    c.addLine(to: CGPoint(x: 383, y: 455))
    c.move(to: CGPoint(x: 508, y: 455))
    c.addLine(to: CGPoint(x: 639, y: 455))
    c.strokePath()
    return c.makeImage()!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let url = directory.appendingPathComponent(filename)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, icon(size: size * scale), nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not create \(filename)") }
    }
}
