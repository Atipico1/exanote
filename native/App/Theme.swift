import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// Neutral, low-chroma surfaces with one lime accent. The lime (#D1FE17) is only a fill with
/// near-black ink on it; lime as text on a light surface would be about 1.2:1, so text, links,
/// focus rings and chart marks use `brandText`, a deep lime in light mode. Fill/label pairs keep
/// at least 4.5:1 contrast in both themes.
extension Color {
    /// The page: plain white, so the work area is unmistakable. Notion's values in both themes.
    static let canvas = Color(nsColor: .adaptive(light: .white, dark: NSColor(hex: 0x191919)))
    /// The sidebar: the one gray surface, Notion's light warm gray.
    static let sidebar = Color(nsColor: .adaptive(light: NSColor(hex: 0xF7F7F5), dark: NSColor(hex: 0x202020)))
    static let surface = Color(nsColor: .adaptive(light: .white, dark: NSColor(hex: 0x202020)))
    static let raised = Color(nsColor: .adaptive(light: NSColor(hex: 0xF1F1EF), dark: NSColor(hex: 0x2C2C2C)))
    /// The selected sidebar row: one step darker than the sidebar, like Notion's.
    static let sidebarHover = Color(nsColor: .adaptive(light: NSColor(hex: 0xEEEEEB), dark: NSColor(hex: 0x292929)))
    static let sidebarSelection = Color(nsColor: .adaptive(light: NSColor(hex: 0xEAEAE7), dark: NSColor(hex: 0x2F2F2F)))
    static let hairline = Color(nsColor: .adaptive(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09)))
    static let brandFill = Color(nsColor: NSColor(hex: 0xD1FE17))
    static let ink = Color(nsColor: NSColor(hex: 0x0F1113))
    static let onBrand = ink
    static let brandText = Color(nsColor: .adaptive(light: NSColor(hex: 0x4A6A00), dark: NSColor(hex: 0xD1FE17)))
    static let recording = Color(nsColor: NSColor(hex: 0xDC2626))
    static let success = Color(nsColor: .adaptive(light: NSColor(hex: 0x15803D), dark: NSColor(hex: 0x4ADE80)))
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, quiet }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.app(size: compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 15)
            .padding(.vertical, compact ? 5 : 7)
            .frame(minHeight: compact ? 28 : 34)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .secondary ? Color.hairline : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .onBrand
        case .danger: .white
        case .secondary, .quiet: .primary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .brandFill
        case .danger: .recording
        case .secondary: .raised
        case .quiet: .clear
        }
    }
}

struct IconCircle: View {
    let symbol: String
    var size: CGFloat = 36
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.app(size: size * 0.4, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Color.raised, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.exTitle).tracking(-0.2)
            Spacer(minLength: 12)
            trailing
        }
        .frame(minHeight: 30)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

struct EmptyState<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 10) {
            IconCircle(symbol: symbol, size: 44)
            Text(title).font(.app(size: 15, weight: .semibold)).padding(.top, 4)
            Text(message)
                .font(.app(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action.padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

extension EmptyState where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

struct ViewAllButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("전체 보기")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .font(.app(size: 12))
        .foregroundStyle(.secondary)
    }
}

/// Segmented control drawn as pills, used for page tabs and filters.
struct PillTabs: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let selected = selection == index
                Button { selection = index } label: {
                    Text(options[index])
                        .font(.app(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: max(30, 30 * Typography.shared.scale))
                        .background(selected ? Color.surface : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? Color.hairline : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.raised, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Label("검색어 지우기", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("지우기")
            }
        }
        .font(.app(size: 13))
        .padding(.horizontal, 14)
        .frame(minHeight: max(36, 36 * Typography.shared.scale))
        .background(Color.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Color.brandText : Color.hairline, lineWidth: focused ? 1.5 : 1))
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in focused = true }
    }
}

struct PageContainer<Content: View>: View {
    var maxWidth: CGFloat = 880
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) { content }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
        }
        .background(Color.canvas)
    }
}

/// Renders the Markdown the notes model writes: headings, bullets, checkboxes and inline styles.
struct NotesText: View {
    let markdown: String
    var speakers: [String] = []
    var speakerNames: [String: String] = [:]
    var seek: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                row(line.trimmingCharacters(in: .whitespaces))
            }
        }
        .font(.exBody)
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ line: String) -> some View {
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if line.hasPrefix("# ") {
            // The page title and the tab already name the notes; skip the model's own H1.
            EmptyView()
        } else if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            Text(inline(String(line.dropFirst(level))))
                .font(.app(size: level <= 1 ? 20 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, 12)
        } else if line.hasPrefix("- [ ]") || line.lowercased().hasPrefix("- [x]") {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: line.hasPrefix("- [ ]") ? "square" : "checkmark.square.fill")
                    .foregroundStyle(Color.brandText)
                    .accessibilityHidden(true)
                item(String(line.dropFirst(5)))
            }
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).offset(y: -3).accessibilityHidden(true)
                item(String(line.dropFirst(2)))
            }
        } else {
            Text(inline(line))
        }
    }

    /// Notes items end with "— 화자 N [mm:ss]"; show the speaker as a tag and the time as a jump.
    @ViewBuilder
    private func item(_ text: String) -> some View {
        if let match = text.firstMatch(of: /\s*[—-]\s*([^\[\]]+?)\s*\[(\d{1,2}):(\d{2})\]\s*$/),
           speakers.contains(String(match.output.1).trimmingCharacters(in: .whitespaces)) {
            let speaker = String(match.output.1).trimmingCharacters(in: .whitespaces)
            let seconds = Double((Int(match.output.2) ?? 0) * 60 + (Int(match.output.3) ?? 0))
            let time = "\(match.output.2):\(match.output.3)"
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(inline(String(text[..<match.range.lowerBound])))
                Tag(text: speakerNames[speaker] ?? speaker, color: TagColor.speaker(speaker, in: speakers))
                if let seek {
                    Button(time) { seek(seconds) }
                        .buttonStyle(.plain)
                        .font(.exTimecode)
                        .foregroundStyle(Color.brandText)
                        .help("여기부터 재생")
                } else {
                    Text(time).font(.exTimecode).foregroundStyle(.tertiary)
                }
            }
        } else {
            Text(inline(text))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (try? AttributedString(markdown: trimmed)) ?? AttributedString(trimmed)
    }
}

/// Python writes microsecond ISO dates; Foundation's parser is strict about fraction length.
func parseISODate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let dot = value.firstIndex(of: "."),
       let zone = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        return formatter.date(from: String(value[..<dot]) + String(value[zone...]))
    }
    return formatter.date(from: value)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total)초" }
    let hours = total / 3600, minutes = (total % 3600) / 60
    return hours > 0 ? "\(hours)시간 \(minutes)분" : "\(minutes)분"
}

func shortDate(_ date: Date) -> String {
    "\(date.formatted(.dateTime.month().day())) · \(date.formatted(date: .omitted, time: .shortened))"
}

/// A white band behind the detail column's part of the (clear) window toolbar, so scrolled
/// content slides under it instead of showing through, while the sidebar keeps its gray.
struct ToolbarBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            Color.canvas
                .frame(height: proxy.safeAreaInsets.top)
                .offset(y: -proxy.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarRowAppearance: ViewModifier {
    var selected = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .frame(minHeight: Typography.shared.sidebarRowHeight)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.sidebarSelection : hovering ? Color.sidebarHover : .clear)
                    .padding(.horizontal, 6)
            )
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
    }
}

extension View {
    func sidebarSpacing() -> some View { modifier(SidebarRowAppearance()) }

    func sidebarRow(_ route: Route, selected: Route?) -> some View {
        modifier(SidebarRowAppearance(selected: selected == route)).tag(route)
    }
}

/// Turns off AppKit's accent-colored selection in the sidebar so rows can draw a quiet gray one
/// (`sidebarRow`). Selection itself, arrow keys and ⌫ keep working, and the row text stays in
/// its normal color instead of switching to white.
struct PlainSidebarSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            for table in Self.tables(in: root) where table.style == .sourceList {
                table.selectionHighlightStyle = .none
            }
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
    }
}
