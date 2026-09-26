import AppKit
import CoreText

/// The line icons in the menu. The app ships a tiny slice of the Hugeicons "stroke
/// rounded" font — only the glyphs listed here, a few KB — and paints each glyph
/// into an image so it can be tinted like any other icon. If the font is missing
/// (running the bare binary, which has no Resources folder) every icon falls back to
/// its closest SF Symbol, so the menu still reads correctly.
enum IconFont {
    struct Icon {
        let scalar: UInt32
        /// SF Symbol drawn instead when the bundled font is unavailable.
        let fallback: String

        init(_ scalar: UInt32, _ fallback: String) {
            self.scalar = scalar
            self.fallback = fallback
        }
    }

    static let window     = Icon(0xF1AC5, "macwindow.badge.plus")
    static let eye        = Icon(0xF1C4A, "eye.fill")
    static let eyeOff     = Icon(0xF312D, "eye.slash.fill")
    static let volumeHigh = Icon(0xF2981, "speaker.wave.2.fill")
    static let volumeOff  = Icon(0xF2986, "speaker.slash.fill")
    static let flash      = Icon(0xF1CE8, "bolt.fill")
    static let flashOff   = Icon(0xF1CE7, "bolt.slash.fill")
    static let sparkles   = Icon(0xF266B, "sparkles")
    static let power      = Icon(0xF238B, "power")

    private static let familyName = "hugeicons-stroke-rounded"
    private static var cache: [String: NSImage] = [:]

    /// Registers the bundled font once, on the first icon anyone asks for.
    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: "Hugeicons-ClaudePets",
                                        withExtension: "ttf",
                                        subdirectory: "fonts") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// A square icon image, `pointSize` on a side, painted in `colour`.
    static func image(_ icon: Icon, pointSize: CGFloat, colour: NSColor) -> NSImage? {
        let key = "\(icon.scalar)-\(pointSize)-\(colour.hashValue)"
        if let cached = cache[key] { return cached }

        let made = draw(icon, pointSize: pointSize, colour: colour)
            ?? symbolImage(icon, pointSize: pointSize, colour: colour)
        if let made { cache[key] = made }
        return made
    }

    private static func draw(_ icon: Icon, pointSize: CGFloat, colour: NSColor) -> NSImage? {
        _ = registered
        guard let font = NSFont(name: familyName, size: pointSize),
              let scalar = UnicodeScalar(icon.scalar) else { return nil }

        let text = NSAttributedString(string: String(Character(scalar)),
                                      attributes: [.font: font, .foregroundColor: colour])
        // The glyph sits inside a square em box; centring what it actually draws keeps
        // icons of different shapes optically lined up down the column.
        let drawn = text.size()
        let side = ceil(pointSize)
        let box = NSSize(width: side, height: side)
        return NSImage(size: box, flipped: false) { _ in
            text.draw(at: NSPoint(x: (box.width - drawn.width) / 2,
                                  y: (box.height - drawn.height) / 2))
            return true
        }
    }

    private static func symbolImage(_ icon: Icon, pointSize: CGFloat, colour: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize - 3, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        return NSImage(systemSymbolName: icon.fallback, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }
}
