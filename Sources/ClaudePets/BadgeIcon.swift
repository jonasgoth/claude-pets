import AppKit
import SpriteKit

/// Renders SF Symbols to crisp white SKTextures for use inside colored status badges.
/// Cached so each symbol is drawn once.
enum BadgeIcon {
    private static var cache: [String: SKTexture] = [:]

    static func texture(_ symbolName: String, pointSize: CGFloat = 11, weight: NSFont.Weight = .bold) -> SKTexture {
        let key = "\(symbolName)-\(Int(pointSize))"
        if let cached = cache[key] { return cached }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: pointSize, height: pointSize))

        // Paint the symbol solid white on transparent so it reads on any badge color.
        let size = base.size
        let white = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceIn)
            return true
        }
        white.isTemplate = false
        let texture = SKTexture(image: white)
        cache[key] = texture
        return texture
    }
}
