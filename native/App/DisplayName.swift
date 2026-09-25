import AppKit
import SwiftUI

enum DisplayName {
    static let key = "displayName"

    static func resolved(_ saved: String) -> String {
        let name = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? NSFullUserName() : name
    }

    static func greeting(_ saved: String) -> String {
        let name = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return NSFullUserName().split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }
}

struct DisplayNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayName.key) private var savedName = ""
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("표시 이름 변경")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("표시 이름")
                    .font(.subheadline.weight(.medium))
                TextField("표시 이름", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
                Text("홈과 사이드바에 표시돼요. 이 Mac에서만 바뀝니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Mac 이름 사용") {
                    savedName = ""
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장", action: save)
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    .disabled(trimmedName.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 390)
        .onAppear {
            draftName = DisplayName.resolved(savedName)
            nameFocused = true
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        savedName = trimmedName
        dismiss()
    }
}
