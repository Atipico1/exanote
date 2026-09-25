import SwiftUI
import AVFoundation

/// In-app playback, like Voice Memos: no hand-off to Music, which would import the file.
@MainActor
final class AudioPlayback: ObservableObject {
    @Published private(set) var playing = false
    @Published private(set) var current: Double = 0
    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?

    var isLoaded: Bool { player != nil }
    var duration: Double { player?.duration ?? 0 }

    func load(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        current = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            playing = false
            timer?.invalidate()
        } else {
            if player.currentTime >= player.duration - 0.2 { player.currentTime = 0 }
            player.play()
            playing = true
            startTimer()
        }
    }

    func play(from seconds: Double) {
        guard let player else { return }
        player.currentTime = seconds
        current = seconds
        if !player.isPlaying {
            player.play()
            playing = true
            startTimer()
        }
    }

    func stop() {
        player?.stop()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        current = player.currentTime
        if !player.isPlaying {
            playing = false
            timer?.invalidate()
        }
    }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct PlayButton: View {
    @ObservedObject var playback: AudioPlayback

    var body: some View {
        Button { playback.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                Text("\(clock(playback.current)) / \(clock(playback.duration.rounded()))").font(.exTimecode)
            }
            .fixedSize()
        }
        .buttonStyle(PillButtonStyle(compact: true))
        .accessibilityLabel(playback.playing ? "일시정지" : "녹음 재생")
        .help(playback.playing ? "일시정지" : "녹음 듣기")
    }
}

/// What the detail screen needs, from either a local result or a synced folder.
struct MeetingDocument {
    let title: String
    let date: Date
    let duration: Double?
    let speakers: Int?
    let language: String?
    let notes: String
    let lines: [TranscriptLine]
    var speakerNames: [String: String] = [:]
    /// This Mac's own meetings only; a synced copy carries them inside its notes.
    var memo = ""
    var bookmarks: [Bookmark] = []

    func displayName(_ speaker: String) -> String { speakerNames[speaker] ?? speaker }

    var namedNotes: String {
        guard !speakerNames.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"화자 [0-9]+(?![0-9])"#) else { return notes }
        var result = notes
        for match in regex.matches(in: notes, range: NSRange(notes.startIndex..., in: notes)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: displayName(String(result[range])))
        }
        return result
    }

    /// Plain Markdown for copy, share and export.
    var markdown: String {
        // One top-level title: the notes' own headings move down a level.
        let body = namedNotes.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("#") ? "#" + $0 : String($0) }
            .joined(separator: "\n")
        var parts = ["# \(title)", "", "\(date.formatted(date: .long, time: .shortened))\(duration.map { " · " + formatDuration($0) } ?? "")", "", body]
        let memo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memo.isEmpty { parts += ["", "## 내 메모", "", memo] }
        if !bookmarks.isEmpty {
            parts += ["", "## 북마크", ""] + bookmarks.map { "- [\(clock($0.time))]" + ($0.note.isEmpty ? "" : " \($0.note)") }
        }
        if !lines.isEmpty {
            parts += ["", "## 전사", ""] + lines.map { "**[\($0.time)] \(displayName($0.speaker))** \($0.text)" }
        }
        return parts.joined(separator: "\n")
    }

    var languageName: String? {
        guard let language else { return nil }
        return Locale.current.localizedString(forLanguageCode: language) ?? language
    }
}

struct TranscriptLine: Identifiable {
    let id: Int
    let start: Double
    var end: Double? = nil
    let speaker: String
    let text: String

    var seconds: Int { Int(start) }
    var time: String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }

    /// Reads the "**[mm:ss] 화자 N** text" lines that storage.py writes.
    static func parse(_ markdown: String) -> [TranscriptLine] {
        markdown.split(separator: "\n").enumerated().compactMap { index, raw in
            let line = String(raw)
            guard line.hasPrefix("**["),
                  let close = line.range(of: "] "),
                  let end = line.range(of: "** ", range: close.upperBound..<line.endIndex) else { return nil }
            let clock = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: ":").compactMap { Int($0) }
            let seconds = clock.count == 2 ? clock[0] * 60 + clock[1] : 0
            return TranscriptLine(id: index, start: Double(seconds), speaker: String(line[close.upperBound..<end.lowerBound]), text: String(line[end.upperBound...]))
        }
    }
}

private func timeRange(_ start: Date, _ duration: Double?) -> String {
    let from = start.formatted(date: .omitted, time: .shortened)
    guard let duration, duration >= 60 else { return from }
    return "\(from) – \(start.addingTimeInterval(duration).formatted(date: .omitted, time: .shortened))"
}

/// Where a meeting lives, shown as a select option in the properties.
struct StorageTag {
    let name: String
    let symbol: String
    let text: String
    let color: TagColor
}

/// Title with actions, then Notion-style properties.
struct MeetingHeader<Actions: View>: View {
    let title: String
    let date: Date
    let duration: Double?
    let storage: StorageTag?
    var document: MeetingDocument? = nil
    var onRenameSpeaker: ((String, String) -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Text(title)
                    .font(.exDisplay)
                    .tracking(Font.displayTracking)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions.fixedSize().padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                PropertyRow(symbol: "calendar", name: "날짜") {
                    Text("\(date.formatted(.dateTime.year().month().day().weekday(.abbreviated))) \(timeRange(date, duration))")
                        .font(.exData)
                }
                if let duration {
                    PropertyRow(symbol: "clock", name: "길이") { Text(formatDuration(duration)).font(.exData) }
                }
                if let document, !document.speakerOrder.isEmpty {
                    PropertyRow(symbol: "person.2", name: "말한 사람") {
                        HStack(spacing: 6) {
                            ForEach(document.speakerOrder, id: \.self) { speaker in
                                SpeakerTag(speaker: speaker, name: document.displayName(speaker),
                                           color: TagColor.speaker(speaker, in: document.speakerOrder),
                                           onRename: onRenameSpeaker)
                            }
                        }
                    }
                }
                if let language = document?.languageName {
                    PropertyRow(symbol: "globe", name: "언어") { Tag(text: language) }
                }
                if let document, !document.noteSections.isEmpty {
                    PropertyRow(symbol: "list.bullet", name: "노트") {
                        HStack(spacing: 6) {
                            ForEach(document.noteSections) { Tag(text: "\($0.title) \($0.count)", color: $0.color) }
                        }
                    }
                }
                if let storage {
                    PropertyRow(symbol: storage.symbol, name: storage.name) { Tag(text: storage.text, color: storage.color) }
                }
            }
        }
    }
}

struct SpeakerTag: View {
    let speaker: String
    let name: String
    let color: TagColor
    var onRename: ((String, String) -> Void)? = nil
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("화자 이름", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: max(100, min(200, CGFloat(draft.count) * 13 + 32)))
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { wasFocused, isFocused in
                        if wasFocused && !isFocused && editing { save() }
                    }
                    .accessibilityLabel("\(name) 이름 수정")
            } else if onRename != nil {
                Tag(text: name, color: color)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEditing)
                    .contextMenu {
                        Button("이름 변경…", action: beginEditing)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "이름 변경", beginEditing)
                    .help("두 번 클릭하여 이름 변경")
            } else {
                Tag(text: name, color: color)
            }
        }
    }

    private func beginEditing() {
        guard onRename != nil else { return }
        draft = name
        editing = true
        focused = true
    }

    private func save() {
        let trimmed = draft.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty else { return }
        editing = false
        if trimmed != name { onRename?(speaker, trimmed) }
    }
}

struct MoreMenu<Items: View>: View {
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            Label("더 보기", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.app(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("더 보기")
    }
}

/// Charts beside the notes on wide windows and above them on narrow ones.
struct DocumentBody: View {
    let document: MeetingDocument
    @ObservedObject var playback: AudioPlayback
    var onRenameSpeaker: ((String, String) -> Void)? = nil
    /// Set for this Mac's meetings: adds the editable 내 메모 tab.
    var memoMeetingID: String? = nil
    var live: LiveSnapshot? = nil
    @State private var tab = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let wide = width >= 820
        Group {
            if wide {
                HStack(alignment: .top, spacing: 44) {
                    main.frame(maxWidth: .infinity, alignment: .leading)
                    insights.frame(width: 280)
                }
            } else {
                VStack(alignment: .leading, spacing: 32) {
                    insights
                    main
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            // ⌘F searches the transcript; switch to it, then focus its field once it exists.
            guard tab == 0 else { return }
            tab = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 20) {
            PillTabs(options: ["회의 노트", "전사 \(document.lines.count)"]
                     + ((live?.rows.isEmpty == false) ? ["실시간 번역"] : [])
                     + (memoMeetingID == nil ? [] : [document.memo.isEmpty ? "내 메모" : "내 메모 ✎"]),
                     selection: $tab).fixedSize()
            if tab == 0 {
                if document.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    EmptyState(symbol: "doc.text", title: "노트가 비어 있어요", message: "전사된 발화가 없거나 요약을 만들지 못했어요.")
                } else {
                    NotesText(markdown: document.notes, speakers: document.speakerOrder, speakerNames: document.speakerNames,
                              seek: playback.isLoaded ? { playback.play(from: $0) } : nil)
                }
            } else if tab == 1 {
                TranscriptView(document: document, playback: playback, onRenameSpeaker: onRenameSpeaker)
            } else if tab == 2, let live, !live.rows.isEmpty {
                LiveTranscriptView(snapshot: live, error: nil, paused: true, archived: true)
            } else if let memoMeetingID {
                MemoEditor(model: AppModel.shared, meetingID: memoMeetingID, initial: document.memo)
            }
        }
    }

    @ViewBuilder
    private var insights: some View {
        if !document.lines.isEmpty || !document.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                BookmarkList(bookmarks: document.bookmarks, seek: playback.isLoaded ? { playback.play(from: $0) } : nil)
                if !document.lines.isEmpty {
                    SpeakerShareView(document: document)
                    SpeakerTimeline(document: document, playback: playback)
                }
            }
        }
    }
}

struct TranscriptView: View {
    let document: MeetingDocument
    @ObservedObject var playback: AudioPlayback
    var onRenameSpeaker: ((String, String) -> Void)? = nil
    @State private var speakerFilter = 0
    @State private var query = ""

    private var lines: [TranscriptLine] { document.lines }
    private var speakers: [String] { document.speakerOrder }

    private var filtered: [TranscriptLine] {
        lines.filter { line in
            (speakerFilter == 0 || line.speaker == speakers[speakerFilter - 1])
                && (query.isEmpty || line.text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if speakers.count > 1 {
                    PillTabs(options: ["전체"] + speakers.map(document.displayName), selection: $speakerFilter).fixedSize()
                }
                SearchField(text: $query, prompt: "대화 내용 검색")
            }
            if filtered.isEmpty {
                EmptyState(symbol: "text.magnifyingglass", title: lines.isEmpty ? "전사된 발화가 없어요" : "일치하는 발화가 없어요",
                           message: lines.isEmpty ? "녹음에서 말소리를 찾지 못했어요." : "다른 검색어나 화자를 선택해 보세요.")
            } else {
                let active = playback.current > 0 ? lines.last(where: { $0.start <= playback.current + 0.3 })?.id : nil
                let marked = markedLines
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, line in
                        // Consecutive lines by the same speaker read as one turn.
                        let continues = index > 0 && filtered[index - 1].speaker == line.speaker
                        row(line, showSpeaker: !continues, active: line.id == active, marked: marked.contains(line.id))
                    }
                }
            }
        }
    }

    /// Lines during which the user set a bookmark.
    private var markedLines: Set<Int> {
        Set(document.bookmarks.compactMap { mark in lines.last(where: { $0.start <= mark.time + 0.5 })?.id })
    }

    private func row(_ line: TranscriptLine, showSpeaker: Bool, active: Bool, marked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Group {
                if playback.isLoaded {
                    Button { playback.play(from: line.start) } label: { Text(line.time) }
                        .buttonStyle(.plain)
                        .foregroundStyle(active ? Color.brandText : Color.secondary)
                        .help("여기부터 재생")
                } else {
                    Text(line.time).foregroundStyle(.tertiary)
                }
            }
            .font(.exTimecode)
            .frame(width: 40, alignment: .leading)
            .overlay(alignment: .leading) {
                if marked {
                    Image(systemName: "flag.fill").font(.app(size: 9)).foregroundStyle(TagColor.orange.solid)
                        .offset(x: -14).help("북마크").accessibilityLabel("북마크")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if showSpeaker {
                    SpeakerTag(speaker: line.speaker, name: document.displayName(line.speaker),
                               color: TagColor.speaker(line.speaker, in: speakers), onRename: onRenameSpeaker)
                }
                Text(highlighted(line.text))
                    .font(.exBody)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, showSpeaker ? 10 : 0)
        .hoverRow(active: active)
        .accessibilityElement(children: .combine)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return result }
        var searchRange = result.startIndex..<result.endIndex
        while let found = result[searchRange].range(of: query, options: .caseInsensitive) {
            result[found].backgroundColor = TagColor.yellow.fill
            searchRange = found.upperBound..<result.endIndex
        }
        return result
    }
}

struct LocalMeetingView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject private var session = AppModel.shared.session
    @EnvironmentObject private var actions: MeetingActions
    @StateObject private var playback = AudioPlayback()

    var body: some View {
        PageContainer(maxWidth: 1120) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.app(size: 12))
                    .foregroundStyle(Color.recording)
                    .textSelection(.enabled)
            }
            if let meeting = store.selected {
                content(meeting)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .task(id: (store.selected?.id ?? "") + (store.selected?.status ?? "")) {
            guard let meeting = store.selected, meeting.status == "done" else { playback.stop(); return }
            playback.load(LocalAPI.dataDirectory.appending(path: meeting.id).appending(path: meeting.filename))
        }
        .onDisappear { playback.stop() }
    }

    private func document(_ meeting: Meeting) -> MeetingDocument? {
        guard meeting.status == "done", let result = meeting.result else { return nil }
        return MeetingDocument(
            title: meeting.title, date: meeting.createdAt, duration: meeting.duration, speakers: meeting.speakers,
            language: meeting.language, notes: result.notes,
            lines: result.utterances.enumerated().map { TranscriptLine(id: $0, start: $1.start, end: $1.end, speaker: $1.speakerLabel, text: $1.text) },
            speakerNames: Dictionary(uniqueKeysWithValues: (meeting.speaker_names ?? [:]).compactMap { key, value in
                guard let index = Int(key) else { return nil }
                return ("화자 \(index + 1)", value)
            }),
            memo: meeting.memo ?? "", bookmarks: meeting.bookmarks ?? [])
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        let document = document(meeting)
        let busy = ["recording", "queued", "processing"].contains(meeting.status)
        MeetingHeader(title: meeting.title, date: meeting.createdAt, duration: meeting.duration, storage: storage(meeting),
                      document: document, onRenameSpeaker: { speaker, name in renameSpeaker(meeting, speaker: speaker, name: name) }) {
            HStack(spacing: 8) {
                FolderPicker(meetingID: meeting.id)
                if document != nil, playback.isLoaded {
                    PlayButton(playback: playback)
                }
                if let document {
                    ShareLink(item: document.markdown, subject: Text(meeting.title)) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                }
                MoreMenu {
                    Button("이름 변경…") { actions.requestRename(id: meeting.id, title: meeting.title) }
                    if let document {
                        Button("노트 복사") { actions.copy(document.markdown) }
                        Button("Markdown으로 내보내기…") { actions.export(title: meeting.title, markdown: document.markdown) }
                    }
                    Divider()
                    Button("Finder에서 보기") { actions.revealLocal(meeting.id) }
                    Button("다시 처리") { retry(meeting) }.disabled(busy || meeting.demo == true)
                    Divider()
                    Button("삭제…", role: .destructive) { actions.requestDelete(id: meeting.id, title: meeting.title) }
                        .disabled(busy)
                }
            }
        }
        Hairline()
        if meeting.recovered == true, meeting.status != "recording" {
            Callout(symbol: "bandage", tint: .yellow,
                    text: "앱이 예기치 않게 종료돼 녹음이 중간에 끊겼어요. 그 전까지 저장된 소리로 노트를 만들었어요.") { EmptyView() }
        }
        switch meeting.status {
        case "done":
            if let document {
                DocumentBody(document: document, playback: playback,
                             onRenameSpeaker: { speaker, name in renameSpeaker(meeting, speaker: speaker, name: name) },
                             memoMeetingID: meeting.id, live: meeting.live)
                    .id(meeting.id)
            }
        case "error":
            EmptyState(symbol: "exclamationmark.triangle", title: "처리하지 못했어요", message: meeting.error ?? "알 수 없는 오류가 발생했어요.") {
                Button { retry(meeting) } label: { Label("다시 처리", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        case "recording":
            if session.meetingID == meeting.id {
                RecordingPage(model: AppModel.shared, session: session, meeting: meeting)
            } else {
                EmptyState(symbol: "waveform", title: "녹음을 마무리하고 있어요", message: "잠시 뒤 저장된 부분까지 전사와 요약을 시작해요.")
            }
        default:
            ProcessingStatusView(meeting: meeting)
            if store.live?.meeting_id == meeting.id {
                LiveTranscriptView(snapshot: store.live, error: store.liveError, paused: true)
            }
            MemoEditor(model: AppModel.shared, meetingID: meeting.id, initial: meeting.memo ?? "",
                       placeholder: "노트를 만드는 동안 회의에 대해 더 적어 둘 수 있어요.")
            BookmarkList(bookmarks: meeting.bookmarks ?? [], seek: nil)
        }
    }

    private func storage(_ meeting: Meeting) -> StorageTag? {
        if meeting.demo == true {
            return StorageTag(name: "저장 위치", symbol: "laptopcomputer", text: "예시 데이터 · 이 Mac", color: .gray)
        }
        if let sync = workspace.syncLabel(for: meeting) {
            let saved = sync.symbol == "checkmark.circle"
            return StorageTag(name: "저장 위치", symbol: "externaldrive", text: sync.text, color: saved ? .green : .yellow)
        }
        return meeting.status == "done" ? StorageTag(name: "저장 위치", symbol: "externaldrive", text: "이 Mac에만 저장", color: .gray) : nil
    }

    private func retry(_ meeting: Meeting) {
        Task {
            await workspace.retry(meetingID: meeting.id)
            try? await store.refresh()
        }
    }

    private func renameSpeaker(_ meeting: Meeting, speaker: String, name: String) {
        guard speaker.hasPrefix("화자 "), let number = Int(speaker.dropFirst(3)), number > 0 else { return }
        Task { await store.renameSpeaker(meetingID: meeting.id, speaker: number - 1, name: name) }
    }
}

struct SharedMeetingView: View {
    let meetingID: String
    @ObservedObject var workspace: WorkspaceStore
    @EnvironmentObject private var actions: MeetingActions
    @State private var meeting: SharedMeeting?
    @State private var failure: String?
    @StateObject private var playback = AudioPlayback()  // Audio stays on the recorder's Mac.

    var body: some View {
        PageContainer(maxWidth: 1120) {
            if let meeting {
                let document = MeetingDocument(
                    title: meeting.title, date: meeting.createdAt, duration: meeting.duration, speakers: meeting.speakers,
                    language: meeting.language, notes: meeting.summary ?? "", lines: TranscriptLine.parse(meeting.transcript ?? ""))
                let author = meeting.mine == true
                    ? StorageTag(name: "기록한 곳", symbol: "desktopcomputer", text: "내 다른 Mac", color: .gray)
                    : StorageTag(name: "기록한 사람", symbol: "person", text: meeting.author, color: .purple)
                MeetingHeader(title: meeting.title, date: meeting.createdAt, duration: meeting.duration, storage: author,
                              document: meeting.stillSyncing ? nil : document) {
                    if !meeting.stillSyncing {
                        HStack(spacing: 8) {
                            ShareLink(item: document.markdown, subject: Text(meeting.title)) {
                                Label("공유", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(PillButtonStyle(compact: true))
                            MoreMenu {
                                Button("노트 복사") { actions.copy(document.markdown) }
                                Button("Markdown으로 내보내기…") { actions.export(title: meeting.title, markdown: document.markdown) }
                                if let folder = meeting.folder {
                                    Divider()
                                    Button("Finder에서 보기") { actions.reveal(folder: folder) }
                                }
                            }
                        }
                    }
                }
                Hairline()
                if meeting.stillSyncing {
                    EmptyState(symbol: "arrow.triangle.2.circlepath", title: "아직 동기화 중이에요", message: "파일이 도착하면 자동으로 표시돼요.")
                } else {
                    DocumentBody(document: document, playback: playback)
                        .id(meeting.id)
                }
            } else if let failure {
                EmptyState(symbol: "exclamationmark.triangle", title: "공유 회의를 열 수 없어요", message: failure)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .task(id: meetingID) {
            meeting = nil
            failure = nil
            while !Task.isCancelled {
                do {
                    meeting = try await workspace.meeting(meetingID)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
                if meeting?.stillSyncing != true { break }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
