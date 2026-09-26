import AppKit
import CoreText

/// The Claude Code spinner, rendered small enough for a menu row.
///
/// This is the *same* animation as the hover bubbles: the very glyphs in
/// `HoverBubble.spinnerFrames`, on the same beat as `HoverBubble.spinnerHolds`, just drawn into an
/// image instead of an `SKLabelNode` because `NSMenuItem` takes an image.
enum ClaudeMark {
    static let color = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    /// The menu redraws on a flat 0.1 s timer, so the bubble's holds become repeated ticks:
    /// · · ✢ ✳ ✶ ✻ ✽ ✽ ✻ ✶ ✳ ✢.
    private static let ticks: [String] = zip(HoverBubble.spinnerFrames, HoverBubble.spinnerHolds)
        .flatMap { frame, hold in Array(repeating: frame, count: max(1, Int((hold / 0.1).rounded()))) }
    static var steps: Int { ticks.count }

    private static let box = NSSize(width: 14, height: 14)
    private static let font = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    private static var cache: [Int: NSImage] = [:]

    /// One frame of the twinkle. Frames are drawn once and kept.
    static func image(step: Int) -> NSImage {
        let s = ((step % steps) + steps) % steps
        if let hit = cache[s] { return hit }

        let text = NSAttributedString(string: ticks[s],
                                      attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(text)
        // Centre the *ink* — the glyph's own outline — not its line box. Line boxes carry room for
        // ascenders and descenders these glyphs never use, which pushed the mark above the row's
        // text; glyph-path bounds put the twinkle dead centre next to the title.
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let image = NSImage(size: box, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.textPosition = CGPoint(x: rect.midX - ink.midX, y: rect.midY - ink.midY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = false
        cache[s] = image
        return image
    }
}
