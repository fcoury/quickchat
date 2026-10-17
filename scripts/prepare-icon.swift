import AppKit

// Normalize the generated artwork to the macOS icon canvas. Faint generation
// artifacts outside the tile must not make it appear to be a full-bleed icon.
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL))!
var minX = source.pixelsWide, minY = source.pixelsHigh
var maxX = -1, maxY = -1
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where source.colorAt(x: x, y: y)!.alphaComponent > 0.04 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY, let image = source.cgImage else {
    fatalError("Icon artwork must contain visible pixels")
}
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
let artwork = image.cropping(to: crop)!
let canvas = 1024
let artworkSize: CGFloat = 824
let scale = artworkSize / max(crop.width, crop.height)
let width = crop.width * scale, height = crop.height * scale
let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: (CGFloat(canvas) - width) / 2,
    y: (CGFloat(canvas) - height) / 2, width: width, height: height))
let result = NSBitmapImageRep(cgImage: context.makeImage()!)
try result.representation(using: .png, properties: [:])!.write(to: outputURL)
