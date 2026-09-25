import SwiftUI

/// Settings and onboarding share these pieces: a gray section title over a rounded card whose
/// rows are divided by hairlines, each row a title, a one-line detail and a trailing control.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 16) }
                            row
                                .buttonStyle(PillButtonStyle(compact: true))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        }
                    }
                    .font(.app(size: 13.5))
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.hairline))
                }
            }
            if let footer {
                Text(footer)
                    .font(.app(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A row with an optional icon well, a title, a detail line and a trailing control.
struct SettingsRow<Trailing: View>: View {
    var symbol: String? = nil
    let title: String
    var detail: String? = nil
    var detailColor: Color = .secondary
    @ViewBuilder var trailing: Trailing

    private var heading: some View {
        HStack(spacing: 12) {
            if let symbol { IconWell(symbol: symbol) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: 13.5, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.app(size: 12))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                heading.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                trailing
            }
        }
    }

}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String? = nil, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail, trailing: { EmptyView() })
    }
}

/// An on/off setting drawn as a row with a switch.
struct SettingsToggle: View {
    var symbol: String? = nil
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

struct IconWell: View {
    let symbol: String
    var tint: Color = .primary

    var body: some View {
        Image(systemName: symbol)
            .font(.app(size: 14, weight: .medium))
            .foregroundStyle(tint.opacity(0.8))
            .frame(width: 30, height: 30)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The trailing state of a setup step: done, an action to take, or work in progress.
struct SetupState: View {
    enum Kind {
        case done(String)
        case action(String, () -> Void)
        case progress(Double?)
        case note(String)
    }

    let kind: Kind

    var body: some View {
        switch kind {
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.app(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.success)
        case .action(let title, let action):
            Button(title, action: action).buttonStyle(PillButtonStyle(kind: .secondary, compact: true))
        case .progress(let value):
            if let value {
                HStack(spacing: 8) {
                    ProgressView(value: value).frame(width: 80)
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        case .note(let text):
            Text(text).font(.app(size: 12)).foregroundStyle(.secondary)
        }
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.app(size: 12.5))
            .foregroundStyle(Color.recording)
            .fixedSize(horizontal: false, vertical: true)
    }
}
