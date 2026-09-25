import AppKit
import Observation
import SwiftUI

/// Observable values make every font use update immediately, without rebuilding views by ID.
@Observable
final class Typography {
    static let shared = Typography()
    var fontName: String { didSet { UserDefaults.standard.set(fontName, forKey: "textFont") } }
    var sizeLevel: Int { didSet { UserDefaults.standard.set(sizeLevel, forKey: "textSizeLevel") } }
    var bodySize: Double { Double(10 + sizeLevel * 2) }
    var sidebarSize: Double { Double(10 + sizeLevel * 2) }
    var sidebarRowHeight: CGFloat { CGFloat(19 + sizeLevel * 3) }
    var sidebarSectionGap: CGFloat { CGFloat(5 + sizeLevel) }
    var scale: CGFloat { CGFloat(bodySize / 14) }

    private init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "textFont") ?? "system"
        let stored = defaults.integer(forKey: "textSizeLevel")
        sizeLevel = stored == 0 ? 3 : min(5, max(1, stored))
    }

    func reset() { fontName = "system"; sizeLevel = 3 }

    func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        if fontName == "system" || design == .monospaced {
            return .system(size: size, weight: weight, design: design)
        }
        return .custom(fontName, fixedSize: size).weight(weight)
    }
}

extension Font {
    static func app(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Typography.shared.font(size: size * Typography.shared.scale, weight: weight, design: design)
    }
    static func sidebar(offset: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        Typography.shared.font(size: CGFloat(Typography.shared.sidebarSize) + offset, weight: weight, design: .default)
    }
}

struct TypographySettings: View {
    @Bindable private var typography = Typography.shared
    private let fonts = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    var body: some View {
        SettingsSection("글자") {
            SettingsRow(symbol: "textformat", title: "글꼴", detail: "사이드바, 설정, 회의 본문에 바로 적용돼요") {
                Picker("글꼴", selection: $typography.fontName) {
                    Text("시스템 기본").tag("system")
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("글자 크기").font(.app(size: 13.5, weight: .medium))
                    Spacer()
                    Text("\(typography.sizeLevel)단계" + (typography.sizeLevel == 3 ? " · 기본" : ""))
                        .font(.app(size: 12)).foregroundStyle(.secondary)
                }
                Text("사이드바와 본문의 크기를 함께 조절해요")
                    .font(.app(size: 12)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(typography.sizeLevel) },
                                      set: { typography.sizeLevel = Int($0.rounded()) }), in: 1...5, step: 1) {
                    Text("글자 크기")
                }
                .labelsHidden()
                .accessibilityValue("\(typography.sizeLevel)단계, 전체 5단계")
                HStack {
                    ForEach(1...5, id: \.self) { level in
                        if level > 1 { Spacer() }
                        Text(level == 1 ? "작게" : level == 3 ? "기본" : level == 5 ? "크게" : "·")
                            .font(.app(size: 11))
                            .foregroundStyle(level == typography.sizeLevel ? Color.brandText : Color.secondary)
                    }
                }
                .accessibilityHidden(true)
            }
            SettingsRow(title: "미리 보기", detail: "회의에서 나눈 이야기를 편하게 읽어 보세요.") {
                Button("기본값으로") { typography.reset() }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}
