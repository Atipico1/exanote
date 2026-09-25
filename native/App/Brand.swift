import SwiftUI

// Exanote's brand in code. The idea is precision: Exanote places every word at the moment it
// was said. The mark and the wordmark come from scripts/brand_assets.py, which also draws the
// app icon from the same coordinates.

/// The mark: a page folded at its top-right corner; two slits cut in from the right make it an E.
/// Coordinates are fractions of the tile side, identical to scripts/brand_assets.py.
struct LogoMark: View {
    var size: CGFloat = 24

    private static let tile = Color(nsColor: NSColor(hex: 0x16181B))
    static let menuBarIdle = menuBarImage(busy: false)
    static let menuBarBusy = menuBarImage(busy: true)

    /// The mark in a unit square (the tile): the page, whose outline takes in the two slits, and
    /// the fold, a separate triangle freed by the cut left of 0.59. With the default cut of 0.03
    /// this is PAGE and FOLD of scripts/brand_assets.py; small renderings widen the cut so it stays open.
    static func outline(cut: Double = 0.03) -> Path {
        let fold = 0.59, points = { (list: [(Double, Double)]) in list.map { CGPoint(x: $0.0, y: $0.1) } }
        var mark = Path()
        mark.addLines(points([(0.26, 0.21), (fold - cut, 0.21), (fold - cut, 0.36), (0.435, 0.36), (0.435, 0.435), (0.74, 0.435),
                              (0.74, 0.565), (0.435, 0.565), (0.435, 0.64), (0.74, 0.64), (0.74, 0.79), (0.26, 0.79)]))
        mark.closeSubpath()
        mark.addLines(points([(fold, 0.21), (0.74, 0.36), (fold, 0.36)]))
        mark.closeSubpath()
        return mark
    }

    /// The mark alone as a menu bar template image, so macOS tints it for a light or dark bar.
    /// While meetings are being transcribed a dot sits at its lower right, cut free of the mark.
    private static func menuBarImage(busy: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The mark spans 0.58 of the tile's height; draw it 14 pt tall, centered.
            let scale = 14 / 0.58
            let place = CGAffineTransform(translationX: side / 2 - 0.5 * scale, y: side / 2 - 0.5 * scale).scaledBy(x: scale, y: scale)
            context.addPath(outline(cut: 0.05).applying(place).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            if busy {
                let dot = CGRect(x: side - 7, y: side - 7, width: 7, height: 7)
                context.setBlendMode(.clear)
                context.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                context.setBlendMode(.normal)
                context.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    var body: some View {
        Canvas { context, canvas in
            context.fill(Self.outline().applying(CGAffineTransform(scaleX: canvas.width, y: canvas.width)), with: .color(.brandFill))
        }
        .frame(width: size, height: size)
        .background(Self.tile, in: RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Exanote with a capital E, semibold and tight; only the x takes the accent.
struct Wordmark: View {
    var size: CGFloat = 15

    var body: some View {
        (Text("E") + Text("x").foregroundStyle(Color.brandText) + Text("anote"))
            .font(.app(size: size, weight: .semibold))
            .tracking(size * -0.02)
            .accessibilityLabel("Exanote")
    }
}

/// Type roles. Headings are set tight and steady, and every number the app measures lines up
/// digit for digit: pure timecodes and shares (0:29, 51%) in SF Mono, values that mix in Hangul
/// (오후 11:05, 29초) in SF Pro with tabular digits, because Hangul in a monospaced design
/// spaces out like a typewriter. Hangul falls back to Apple SD Gothic Neo in every role.
extension Font {
    /// Page titles: the greeting, 회의, a meeting's title. Use with `.tracking(Font.displayTracking)`.
    static var exDisplay: Font { Font.app(size: 30, weight: .semibold) }
    static let displayTracking: CGFloat = -0.7
    /// Section headers.
    static var exTitle: Font { Font.app(size: 17, weight: .semibold) }
    /// Row and card titles.
    static var exHeadline: Font { Font.app(size: 14, weight: .medium) }
    /// Notes and transcript text.
    static var exBody: Font { Font.app(size: 14) }
    /// Dates and durations that include Hangul: tabular digits.
    static var exData: Font { Font.app(size: 12.5, weight: .medium).monospacedDigit() }
    static var exDataSmall: Font { Font.app(size: 11).monospacedDigit() }
    /// Pure timecodes, shares and counts: 0:29, 51%, 2/5.
    static var exTimecode: Font { Font.app(size: 12.5, weight: .medium, design: .monospaced) }
    static var exTimecodeSmall: Font { Font.app(size: 11, design: .monospaced) }
    /// Labels that sit above or beside data: column headers, today's date.
    static var exEyebrow: Font { Font.app(size: 11.5, weight: .medium) }
    /// The running recording timer.
    static var exTimer: Font { Font.app(size: 13, weight: .semibold, design: .monospaced) }
}
