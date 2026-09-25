import AppKit
import Observation
import SwiftUI

/// Observable values make every font use update immediately, without rebuilding views by ID.
@Observable
final class Typography {
    static let shared = Typography()
    var fontName: String { didSet { UserDefaults.standard.set(fontName, forKey: "textFont") } }
    var bodySize: Double { didSet { UserDefaults.standard.set(bodySize, forKey: "textSize") } }
    var sidebarSize: Double { didSet { UserDefaults.standard.set(sidebarSize, forKey: "sidebarTextSize") } }
    var scale: CGFloat { CGFloat(bodySize / 14) }

    private init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "textFont") ?? "system"
        let body = defaults.double(forKey: "textSize"), sidebar = defaults.double(forKey: "sidebarTextSize")
        bodySize = body == 0 ? 14 : min(20, max(12, body))
        sidebarSize = sidebar == 0 ? 16 : min(22, max(13, sidebar))
    }

    func reset() { fontName = "system"; bodySize = 14; sidebarSize = 16 }

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
            SettingsRow(title: "본문 글자 크기") {
                Stepper("\(Int(typography.bodySize)) pt", value: $typography.bodySize, in: 12...20, step: 1)
                    .fixedSize()
            }
            SettingsRow(title: "사이드바 글자 크기", detail: "메뉴, 회의 제목, 폴더 이름을 따로 조절해요") {
                Stepper("\(Int(typography.sidebarSize)) pt", value: $typography.sidebarSize, in: 13...22, step: 1)
                    .fixedSize()
            }
            SettingsRow(title: "미리 보기", detail: "회의에서 나눈 이야기를 편하게 읽어 보세요.") {
                Button("기본값으로") { typography.reset() }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}
