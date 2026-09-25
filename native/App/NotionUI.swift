import AppKit
import SwiftUI

/// Notion's select-option colors: a pastel fill with dark text in light mode and a muted fill
/// with light text in dark mode. `solid` is the stronger shade used for charts.
enum TagColor: Int, CaseIterable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red

    private var values: (light: UInt32, lightText: UInt32, dark: UInt32, solid: UInt32) {
        switch self {
        case .gray: (0xE3E2E0, 0x32302C, 0x5A5A5A, 0x9B9A97)
        case .brown: (0xEEE0DA, 0x442A1E, 0x603B2C, 0x937264)
        case .orange: (0xFADEC9, 0x49290E, 0x854C1D, 0xFFA344)
        case .yellow: (0xFDECC8, 0x402C1B, 0x89632A, 0xE9B949)
        case .green: (0xDBEDDB, 0x1C3829, 0x2B593F, 0x4DAB9A)
        case .blue: (0xD3E5EF, 0x183347, 0x28456C, 0x529CCA)
        case .purple: (0xE8DEEE, 0x412454, 0x492F64, 0x9A6DD7)
        case .pink: (0xF5E0E9, 0x4C2337, 0x69314C, 0xE255A1)
        case .red: (0xFFE2DD, 0x5D1715, 0x6E3630, 0xFF7369)
        }
    }

    var fill: Color { Color(nsColor: .adaptive(light: NSColor(hex: values.light), dark: NSColor(hex: values.dark))) }
    var text: Color { Color(nsColor: .adaptive(light: NSColor(hex: values.lightText), dark: NSColor(white: 1, alpha: 0.9))) }
    var solid: Color { Color(nsColor: NSColor(hex: values.solid)) }

    private static let speakerOrder: [TagColor] = [.blue, .green, .orange, .purple, .pink, .yellow, .red, .brown]

    /// Stable color per speaker label; unknown speakers stay gray.
    static func speaker(_ label: String, in order: [String]) -> TagColor {
        guard label != "미확인", let index = order.firstIndex(of: label) else { return .gray }
        return speakerOrder[index % speakerOrder.count]
    }
}

/// A Notion select option.
struct Tag: View {
    let text: String
    var color: TagColor = .gray
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.app(size: 10, weight: .semibold)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.app(size: 12.5))
        .foregroundStyle(color.text)
        .padding(.horizontal, 6)
        .frame(height: 21)
        .background(color.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
    }
}

/// A Notion page property: gray icon and name on the left, the value on the right.
struct PropertyRow<Value: View>: View {
    let symbol: String
    let name: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
                Text(name)
            }
            .foregroundStyle(.secondary)
            .frame(width: 132, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.app(size: 13.5))
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

/// Flat block on the page canvas; content sits directly on the background like a document.
struct Block<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.vertical, padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small gray heading for a page section, like Notion's database or sidebar group titles.
struct BlockTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.app(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// Notion-style list row: no container, a rounded hover highlight, and text aligned with the page.
struct HoverRow: ViewModifier {
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background((active || hovering) ? Color.primary.opacity(active ? 0.06 : 0.04) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .padding(.horizontal, -8)
    }
}

extension View {
    func hoverRow(active: Bool = false) -> some View { modifier(HoverRow(active: active)) }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.hairline).frame(height: 1) }
}
