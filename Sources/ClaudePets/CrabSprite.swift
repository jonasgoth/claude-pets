import AppKit
import SpriteKit
import CoreImage

/// The pixel crab. 20 walk-cycle frames in one horizontal strip, 51×36 px each.
/// Source: Assets/crab-walk-strip.png (see Assets/ATTRIBUTION.md). Embedded here so the
/// app has no resource-bundle lookup to get wrong.
enum CrabSprite {
    static let frameSize = CGSize(width: 51, height: 36)
    static let frameCount = 20

    private static let stripBase64 = [
        "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",
    ].joined()

    static let stripImage: NSImage = {
        guard let data = Data(base64Encoded: stripBase64), let image = NSImage(data: data) else {
            fatalError("Claude Pets: crab sprite strip is corrupt")
        }
        return image
    }()

    /// Walk cycle, nearest-neighbour filtered so the pixels stay crisp when scaled up.
    static let walkTextures: [SKTexture] = {
        let strip = SKTexture(image: stripImage)
        strip.filteringMode = .nearest
        let w = 1.0 / CGFloat(frameCount)
        return (0..<frameCount).map { i in
            let t = SKTexture(rect: CGRect(x: CGFloat(i) * w, y: 0, width: w, height: 1), in: strip)
            t.filteringMode = .nearest
            return t
        }
    }()

    static var idleTexture: SKTexture { walkTextures[0] }

    /// The crab's own hue (terracotta), in degrees. Palette colors are reached by rotating from here.
    static let baseHueDegrees: CGFloat = 14

    private static var tintCache: [Int: [SKTexture]] = [:]

    /// Walk-cycle frames recolored to `targetHueDegrees` by rotating the sprite's hue. Unlike a flat
    /// color blend this keeps the pixel shading (light body, darker legs) and leaves the near-black
    /// eyes black. Rendered once per hue and cached.
    static func walkTextures(hueDegrees targetHueDegrees: CGFloat) -> [SKTexture] {
        let key = Int(targetHueDegrees.rounded())
        if let cached = tintCache[key] { return cached }

        let rotation = (targetHueDegrees - baseHueDegrees) * .pi / 180
        let frames: [SKTexture]
        if abs(rotation) < 0.001 {
            frames = walkTextures
        } else if let rotated = rotatedStrip(byRadians: rotation) {
            rotated.filteringMode = .nearest
            let w = 1.0 / CGFloat(frameCount)
            frames = (0..<frameCount).map { i in
                let t = SKTexture(rect: CGRect(x: CGFloat(i) * w, y: 0, width: w, height: 1), in: rotated)
                t.filteringMode = .nearest
                return t
            }
        } else {
            frames = walkTextures
        }
        tintCache[key] = frames
        return frames
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func rotatedStrip(byRadians angle: CGFloat) -> SKTexture? {
        guard let tiff = stripImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIHueAdjust") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: Double(angle)), forKey: kCIInputAngleKey)
        guard let output = filter.outputImage,
              let outCG = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return SKTexture(cgImage: outCG)
    }

    /// Frame 0 drawn crisp at menu-bar height.
    static func menuBarImage(height: CGFloat = 18) -> NSImage {
        let width = (height * frameSize.width / frameSize.height).rounded()
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            stripImage.draw(in: rect,
                            from: NSRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height),
                            operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}
