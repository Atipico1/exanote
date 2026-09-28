import SwiftUI

/// A running, speaker-labelled note made only from words the live worker has heard.
/// The final meeting summary is still generated from the saved recording after stop.
struct LiveNotesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let snapshot: LiveSnapshot?
    let error: String?
    let paused: Bool
    var compact = false

    private var rows: [LiveRow] { Array((snapshot?.rows ?? []).suffix(compact ? 2 : 8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            HStack(spacing: 9) {
                Image(systemName: "note.text").foregroundStyle(compact ? Color.brandFill : Color.brandText)
                    .accessibilityHidden(true)
                Text("실시간 노트").font(compact ? .app(size: 13, weight: .semibold) : .exTitle)
                Spacer(minLength: 4)
                if !compact { Tag(text: "영어 → 한국어", color: .blue) }
                Text("임시 기록").font(.exDataSmall).foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.exDataSmall).foregroundStyle(Color.recording)
            } else if rows.isEmpty && snapshot?.preview == nil {
                HStack(spacing: 8) {
                    if !paused { ProgressView().controlSize(.small) }
                    Text(paused ? "일시정지 중이에요" : "말소리를 기다리고 있어요…")
                        .font(.exBody).foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows) { row in
                    note(speaker: row.speaker, time: row.timestamp,
                         translation: row.translation ?? row.draft_translation,
                         original: row.text)
                    if row.id != rows.last?.id { Hairline() }
                }
                if let preview = snapshot?.preview, !preview.text.isEmpty {
                    if !rows.isEmpty { Hairline() }
                    note(speaker: preview.speaker, time: "듣는 중",
                         translation: preview.translation, original: preview.text)
                }
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Color.white.opacity(0.06) : Color.surface,
                    in: RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
            .strokeBorder(compact ? Color.white.opacity(0.10) : Color.hairline, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: rows.count)
    }

    private func note(speaker: String, time: String, translation: String?, original: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 7) {
                Text(time).font(.exTimecodeSmall).foregroundStyle(.tertiary)
                Text(speaker).font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(compact ? Color.brandFill : Color.brandText)
            }
            Text(original).font(compact ? .app(size: 12.5, weight: .medium) : .exBody)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let translation, !translation.isEmpty {
                Text(translation).font(compact ? .app(size: 11) : .app(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
