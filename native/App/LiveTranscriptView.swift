import SwiftUI

/// A temporary reading surface during recording. The offline pass replaces it
/// with word-aligned transcript rows after the recording ends.
struct LiveTranscriptView: View {
    let snapshot: LiveSnapshot?
    let error: String?
    let paused: Bool
    var archived = false
    var limit = 10

    private var visibleRows: [LiveRow] { archived ? (snapshot?.rows ?? []) : Array((snapshot?.rows ?? []).suffix(limit)) }
    private var speakerOrder: [String] {
        var labels: [String] = []
        for row in snapshot?.rows ?? [] where !labels.contains(row.speaker) { labels.append(row.speaker) }
        return labels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(archived ? "녹음 중 번역 기록" : "실시간 전사·번역", systemImage: "waveform")
                    .font(.exTitle)
                Tag(text: "영어 → 한국어", color: .blue)
                Spacer()
                Text(archived ? "당시 결과" : "임시 결과")
                    .font(.exEyebrow)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.exDataSmall).foregroundStyle(Color.recording)
            } else if let error = snapshot?.translation_error {
                Label("번역 모델을 준비하지 못했어요: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.exDataSmall).foregroundStyle(Color.recording)
            }
            if visibleRows.isEmpty && snapshot?.preview == nil {
                HStack(spacing: 9) {
                    if !paused && error == nil { ProgressView().controlSize(.small) }
                    Text(error != nil ? "녹음은 계속 저장되고 있어요."
                         : paused ? "일시정지 중이에요"
                         : snapshot == nil ? "실시간 모델을 준비하고 있어요…" : "말소리를 기다리고 있어요…")
                        .font(.exBody).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            } else {
                if archived {
                    Text("녹음 중 만든 번역이에요. 정확한 문장과 화자 구분은 전사 탭에서 확인해 주세요.")
                        .font(.exDataSmall).foregroundStyle(.tertiary)
                } else if (snapshot?.rows.count ?? 0) > visibleRows.count {
                    Text("최근 \(visibleRows.count)개 발화 · 전체 번역은 녹음 후 실시간 번역 탭에서 볼 수 있어요")
                        .font(.exDataSmall).foregroundStyle(.tertiary)
                }
                ForEach(visibleRows) { row in
                    rowView(row)
                    if row.id != visibleRows.last?.id { Hairline() }
                }
                if let preview = snapshot?.preview, !preview.text.isEmpty {
                    Hairline()
                    HStack(alignment: .top, spacing: 12) {
                        Tag(text: preview.speaker, color: TagColor.speaker(preview.speaker, in: speakerOrder))
                        VStack(alignment: .leading, spacing: 5) {
                            if preview.overlap == true {
                                Text("겹친 발화 · 임시 문장과 화자를 확인해 주세요")
                                    .font(.exDataSmall).foregroundStyle(Color.orange)
                            }
                            Text(preview.text).font(.exBody).foregroundStyle(.secondary)
                            if preview.overlap == true {
                                Text("화자별로 구분한 뒤 번역해요")
                                    .font(.exDataSmall).foregroundStyle(.tertiary)
                            } else if let translation = preview.translation, !translation.isEmpty {
                                Text(translation).font(.exBody.weight(.medium))
                                Text("듣는 중 · 문장이 확정되면 다듬어요")
                                    .font(.exDataSmall).foregroundStyle(.tertiary)
                            } else if preview.translation_error != nil {
                                Text("임시 번역을 만들지 못했어요").font(.exDataSmall).foregroundStyle(Color.recording)
                            } else {
                                Text("듣는 중 · 문장이 끝나면 번역해요")
                                    .font(.exDataSmall).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
    }

    private func rowView(_ row: LiveRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.timestamp).font(.exTimecodeSmall).foregroundStyle(.tertiary).frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Tag(text: row.speaker, color: TagColor.speaker(row.speaker, in: speakerOrder))
                if row.overlap == true {
                    Text("겹친 발화 · 화자와 문장을 확인해 주세요")
                        .font(.exDataSmall).foregroundStyle(Color.orange)
                }
                Text(row.text).font(.exBody).foregroundStyle(.secondary).textSelection(.enabled)
                if let translation = row.translation, !translation.isEmpty {
                    Text(translation).font(.exBody.weight(.medium)).textSelection(.enabled)
                } else if let draft = row.draft_translation, !draft.isEmpty {
                    Text(draft).font(.exBody.weight(.medium)).textSelection(.enabled)
                    Text("문장 확정 중…").font(.exDataSmall).foregroundStyle(.tertiary)
                } else if row.translation_error != nil {
                    Text("번역하지 못했어요").font(.exDataSmall).foregroundStyle(Color.recording)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("번역 중…")
                    }
                    .font(.exDataSmall).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
