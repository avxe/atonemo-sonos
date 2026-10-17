import AppKit

/// Channel glyphs: the NTS mixtape icons, trimmed, sized to one visual weight and centered on their mass.
enum Glyphs {
    static let side: CGFloat = 48  // points; drawn smaller, so 2x pixels stay sharp

    /// A template image from an icon PNG (black or white on transparent).
    static func polish(_ data: Data) -> NSImage? {
        NSBitmapImageRep(data: data)?.cgImage.flatMap { polish($0) }
    }

    /// "1" and "2" for the live channels, as tall as the icons.
    static func numeral(_ text: String) -> NSImage? {
        let font = NSFont.systemFont(ofSize: 160, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = string.size()
        let image = NSImage(size: NSSize(width: ceil(size.width) + 20, height: ceil(size.height) + 20), flipped: false) { _ in
            string.draw(at: NSPoint(x: 10, y: 10))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { polish($0, longest: 0.6) }
    }

    /// `longest`: the most of the frame the longest side may take.
    static func polish(_ source: CGImage, longest: CGFloat = 0.86) -> NSImage? {
        guard let ink = Ink(source) else { return nil }
        // Scale by the box's geometric mean, nudged by how much of the box is filled,
        // so a thin safety pin and a solid heart look the same size. The longest side stays inside the frame.
        let box = ink.box
        let mean = (box.width * box.height).squareRoot()
        let scale = min(0.62 * side / (mean * pow(ink.fill, 0.18)), longest * side / max(box.width, box.height))
        // Center halfway between the box center and the center of mass: the eye sees the mass.
        let center = CGPoint(x: (box.midX + ink.mass.x) / 2, y: (box.midY + ink.mass.y) / 2)
        let pixels = Int(side * 2)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let s = scale * 2
        let origin = CGPoint(x: CGFloat(pixels) / 2 - center.x * s, y: CGFloat(pixels) / 2 - center.y * s)
        context.draw(source, in: CGRect(x: origin.x, y: origin.y, width: CGFloat(source.width) * s, height: CGFloat(source.height) * s))
        guard let cg = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: side, height: side))
        image.isTemplate = true
        return image
    }

    /// Where the opaque pixels are, in image coordinates with y up (as Core Graphics draws).
    private struct Ink {
        var box: CGRect
        var mass: CGPoint
        var fill: CGFloat  // opaque share of the box, 0...1

        init?(_ image: CGImage) {
            let (w, h) = (image.width, image.height)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            var (minX, minY, maxX, maxY) = (w, h, -1, -1)
            var (total, sumX, sumY) = (0.0, 0.0, 0.0)
            for row in 0..<h {
                let y = h - 1 - row  // memory rows run top-down; drawing runs bottom-up
                for x in 0..<w {
                    let alpha = Double(pixels[(row * w + x) * 4 + 3]) / 255
                    guard alpha > 0.08 else { continue }
                    (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
                    total += alpha
                    sumX += alpha * (Double(x) + 0.5)
                    sumY += alpha * (Double(y) + 0.5)
                }
            }
            guard maxX >= minX, total > 0 else { return nil }
            box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            mass = CGPoint(x: sumX / total, y: sumY / total)
            fill = min(max(CGFloat(total) / (box.width * box.height), 0.05), 1)
        }
    }
}
