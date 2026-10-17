import AppKit
import Testing
@testable import AtonemoSonos

/// A black square in the bottom left corner of a 100 px image.
private func offCenterSquare() -> CGImage {
    let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 5, y: 5, width: 30, height: 30))
    return context.makeImage()!
}

/// Center of the opaque pixels, and the opaque box size, in pixels.
private func ink(_ image: NSImage) -> (center: CGPoint, side: Int) {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    var (sumX, sumY, count, minX, maxX) = (0, 0, 0, Int.max, 0)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
            (sumX, sumY, count, minX, maxX) = (sumX + x, sumY + y, count + 1, min(minX, x), max(maxX, x))
        }
    }
    return (CGPoint(x: Double(sumX) / Double(count), y: Double(sumY) / Double(count)), maxX - minX + 1)
}

@Test func polishCentersAndScales() throws {
    let glyph = try #require(Glyphs.polish(offCenterSquare()))
    #expect(glyph.isTemplate && glyph.size == NSSize(width: Glyphs.side, height: Glyphs.side))
    let (center, side) = ink(glyph)
    let middle = Glyphs.side  // the 2x bitmap is twice `side` wide
    #expect(abs(center.x - middle) < 2 && abs(center.y - middle) < 2)
    #expect(side > 40 && side < 70)  // a solid square fills about 60% of the frame
}

@Test func numeralsAreGlyphs() throws {
    let one = try #require(Glyphs.numeral("1"))
    #expect(one.isTemplate)
    #expect(ink(one).center.x > Glyphs.side - 6 && ink(one).center.x < Glyphs.side + 6)
}
