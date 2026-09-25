import AppKit
import Combine
import SwiftUI

// MARK: Floating panel

/// A small always-on-top bar at the top of the screen while recording, like the call controls of
/// meeting apps. It never takes focus, so clicking it leaves Zoom or the browser in front.
@MainActor
final class RecordingPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private static let originKey = "recordingPillOrigin"
    private static let compactSize = NSSize(width: 470, height: 48)
    private static let expandedSize = NSSize(width: 470, height: 344)

    init(model: AppModel) {
        self.model = model
        model.session.$meetingID.combineLatest(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () }.prepend(())
        )
        .map { id, _ in id != nil && UserDefaults.standard.bool(forKey: RecordingPrefs.showPill) }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] visible in visible ? self?.show() : self?.hide() }
        .store(in: &cancellables)
        model.$liveOverlayExpanded.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] expanded in self?.resize(expanded: expanded) }
            .store(in: &cancellables)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame(expanded: model.liveOverlayExpanded), display: true)
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.compactSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Exanote 녹음"
        let hosting = NSHostingView(rootView: RecordingPill(model: model, session: model.session))
        hosting.frame = NSRect(origin: .zero, size: Self.compactSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                guard self?.model.liveOverlayExpanded == false else { return }
                UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originKey)
            }
            .store(in: &cancellables)
        return panel
    }

    private func resize(expanded: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(frame(expanded: expanded), display: true, animate: true)
    }

    private func frame(expanded: Bool) -> NSRect {
        let size = expanded ? Self.expandedSize : Self.compactSize
        let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let topCenter = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8)
        return NSRect(origin: expanded ? topCenter : (savedOrigin() ?? topCenter), size: size)
    }

    /// Where the user last dragged it, if that spot is still on a connected screen.
    private func savedOrigin() -> NSPoint? {
        guard let text = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let origin = NSPointFromString(text)
        let frame = NSRect(origin: origin, size: Self.compactSize)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) } ? origin : nil
    }
}

struct RecordingPill: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: RecordingSession
    @ObservedObject private var store = AppModel.shared.store

    private var expanded: Bool { model.liveOverlayExpanded && store.recordingMode == .liveTranslation }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RecordingDot(paused: session.paused)
                Text(clock(Double(session.elapsed)))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize()
                LevelBars(levels: session.levels, paused: session.paused, compact: true)
                status
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if store.recordingMode == .liveTranslation {
                    PillIconButton(symbol: expanded ? "chevron.up" : "chevron.down",
                                   help: expanded ? "실시간 노트 접기" : "실시간 노트 펼치기") {
                        model.toggleLiveOverlay()
                    }
                }
                PillIconButton(symbol: "flag", help: "북마크 추가 (⌘⇧B)") { model.addBookmark() }
                    .disabled(session.paused)
                PillIconButton(symbol: session.paused ? "play.fill" : "pause.fill", help: session.paused ? "녹음 재개 (⌘⇧P)" : "일시정지 (⌘⇧P)") {
                    model.togglePause()
                }
                PillIconButton(symbol: "note.text", help: "Exanote에서 메모하기") {
                    model.showMain(route: session.meetingID.map { .local($0) })
                }
                Button { model.stopMeeting() } label: {
                    Text("종료").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Color.recording, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("녹음을 끝내고 노트를 만듭니다")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 48)

            if expanded {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                ScrollView {
                    LiveNotesView(snapshot: store.live?.meeting_id == session.meetingID ? store.live : nil,
                                  error: store.liveError, paused: session.paused, compact: true)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Text("발화별 임시 기록 · 화면 공유에도 보일 수 있어요")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button("전체 보기") { model.showMain(route: session.meetingID.map { .local($0) }) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.brandFill)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 470, height: expanded ? 344 : 48)
        .background(RoundedRectangle(cornerRadius: expanded ? 20 : 24, style: .continuous)
            .fill(Color(white: 0.09).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 24, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .contextMenu {
            Button("Exanote 열기") { model.showMain(route: session.meetingID.map { .local($0) }) }
            Button("화면 위 녹음 표시 끄기") { UserDefaults.standard.set(false, forKey: RecordingPrefs.showPill) }
        }
    }

    @ViewBuilder
    private var status: some View {
        if session.callEnded {
            Button { model.keepRecording() } label: {
                Text("통화 종료됨 · 계속 녹음").foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)
            .help("통화가 끝난 것 같아요. 계속 녹음하려면 누르세요.")
        } else if let flash = session.flash {
            Text(flash).foregroundStyle(Color.brandFill)
        } else if session.noInput || session.deviceProblem != nil {
            Label("소리가 안 들어와요", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.yellow)
                .help(session.deviceProblem ?? "마이크와 시스템 오디오 녹음 권한, 입력 장치를 확인하세요.")
        } else if session.paused {
            Text("일시정지됨").foregroundStyle(.white.opacity(0.7))
        } else if store.recordingMode == .liveTranslation {
            Text("실시간 번역").foregroundStyle(Color.brandFill)
        } else {
            Text("녹음 후 전사").foregroundStyle(.white.opacity(0.7))
        }
    }
}

private struct PillIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.35))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct RecordingDot: View {
    let paused: Bool
    @State private var dim = false

    var body: some View {
        Group {
            if paused {
                Image(systemName: "pause.circle.fill").font(.system(size: 13)).foregroundStyle(Color.orange)
            } else {
                Circle().fill(Color.recording).frame(width: 9, height: 9)
                    .opacity(dim ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
                    .onAppear { dim = true }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityLabel(paused ? "일시정지됨" : "녹음 중")
    }
}

/// Two meters: my microphone and the meeting's sound (system audio).
struct LevelBars: View {
    @ObservedObject var levels: LevelMeter
    let paused: Bool
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 3) {
                bar(levels.microphone, help: "내 마이크")
                bar(levels.system, help: "회의 소리")
            }
            .frame(width: 9, height: 18)
            .opacity(paused ? 0.3 : 1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                row("내 마이크", symbol: "mic", level: levels.microphone)
                row("회의 소리", symbol: "speaker.wave.2", level: levels.system)
            }
            .opacity(paused ? 0.4 : 1)
        }
    }

    private func bar(_ level: Double, help: String) -> some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level > 0.9 ? Color.orange : Color.brandFill)
                    .frame(height: max(2, proxy.size.height * level))
            }
        }
        .background(RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.15)))
        .help(help)
        .accessibilityHidden(true)
    }

    private func row(_ title: String, symbol: String, level: Double) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.raised)
                    Capsule().fill(level > 0.9 ? Color.orange : Color.brandText).frame(width: max(4, proxy.size.width * level))
                }
            }
            .frame(height: 6)
            .animation(.linear(duration: 0.1), value: level)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) 입력 \(Int(level * 100))%")
    }
}

// MARK: Menu bar

struct MenuBarLabel: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var store: MeetingStore

    var body: some View {
        if session.isActive {
            HStack(spacing: 4) {
                Image(systemName: session.paused ? "pause.circle.fill" : "record.circle.fill")
                Text(clock(Double(session.elapsed))).monospacedDigit()
            }
        } else if store.meetings.contains(where: { ["queued", "processing"].contains($0.status) }) {
            Image(nsImage: LogoMark.menuBarBusy).accessibilityLabel("Exanote, 전사 중")
        } else {
            Image(nsImage: LogoMark.menuBarIdle).accessibilityLabel("Exanote")
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: RecordingSession
    @ObservedObject var store: MeetingStore
    @ObservedObject var detector: MeetingDetector
    @ObservedObject var calendar: UpcomingMeetingsStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.isActive {
                recording
            } else {
                idle
            }
            let working = store.meetings.filter { ["queued", "processing"].contains($0.status) }
            if !working.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(working) { meeting in
                        Button { model.showMain(route: .local(meeting.id)) } label: {
                            ProcessingRow(meeting: meeting)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color.recording).lineLimit(3)
            }
            Divider()
            HStack(spacing: 14) {
                Button("Exanote 열기") { model.showMain() }
                Button("설정…") { model.showMain(route: .settings(.general)) }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { if model.openMainWindow == nil { model.openMainWindow = { openWindow(id: "main") } } }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot(paused: session.paused)
                Text(session.paused ? "일시정지됨" : "녹음 중").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(clock(Double(session.elapsed))).font(.system(size: 20, weight: .semibold, design: .monospaced))
            }
            if let title = store.meetings.first(where: { $0.id == session.meetingID })?.title {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            LevelBars(levels: session.levels, paused: session.paused)
            if session.callEnded {
                HStack {
                    Text("통화가 끝난 것 같아요").font(.caption).foregroundStyle(Color.orange)
                    Spacer()
                    Button("계속 녹음") { model.keepRecording() }.buttonStyle(PillButtonStyle(compact: true))
                }
            } else if session.noInput {
                Text("소리가 들어오지 않아요. 입력 장치와 시스템 오디오 녹음 권한을 확인하세요.").font(.caption).foregroundStyle(Color.orange)
            }
            HStack(spacing: 8) {
                Button { model.togglePause() } label: {
                    Label(session.paused ? "재개" : "일시정지", systemImage: session.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PillButtonStyle(compact: true))
                Button { model.addBookmark() } label: { Label("북마크", systemImage: "flag") }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(session.paused)
                Spacer()
                Button { model.stopMeeting() } label: { Text("종료") }
                    .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
            }
        }
    }

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let signal = detector.active {
                Label("\(signal.name)에서 통화 중이에요", systemImage: "waveform").font(.system(size: 13, weight: .semibold))
            } else {
                Text("Exanote").font(.system(size: 13, weight: .semibold))
            }
            Button { model.startMeeting() } label: {
                Label("녹음 시작", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
            .disabled(!model.canStart)
            if let next = calendar.meetings.first(where: { $0.start.timeIntervalSinceNow < 3600 }) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(next.start <= .now ? "진행 중" : next.start.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("이 일정 녹음") { model.startMeeting(next.title) }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(!model.canStart)
                }
            }
        }
    }
}

// MARK: Processing

struct ProcessingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meeting.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                if let progress = meeting.progress {
                    Text("\(Int(progress.fraction * 100))%").font(.exDataSmall).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: meeting.progress?.fraction ?? 0).progressViewStyle(.linear).controlSize(.small)
            Text(processingLine(meeting)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

func processingLine(_ meeting: Meeting) -> String {
    if let progress = meeting.progress {
        if let download = progress.download {
            let got = ByteCountFormatter.string(fromByteCount: Int64(download.bytes), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(download.expected_bytes), countStyle: .file)
            return "\(download.name) 모델 내려받는 중 · \(got) / \(total)"
        }
        if let remaining = progress.remaining {
            return "\(progress.stageName) 중 · 약 \(remaining < 60 ? "1분 미만" : "\(Int((remaining / 60).rounded(.up)))분") 남음"
        }
        return "\(progress.stageName) 중"
    }
    if let ahead = meeting.queue_position, ahead > 0 { return "대기 중 · 앞에 \(ahead)개" }
    return "곧 시작해요"
}

struct ProcessingStatusView: View {
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 12) {
            IconCircle(symbol: "waveform", size: 44)
            Text("전사와 요약을 만들고 있어요").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: meeting.progress?.fraction ?? 0).progressViewStyle(.linear)
                HStack {
                    Text(processingLine(meeting))
                    Spacer()
                    if let progress = meeting.progress { Text("\(Int(progress.fraction * 100))%").font(.exData) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
            Text("모두 이 Mac에서 처리해요. 창을 닫거나 앱을 종료해도 계속 진행되고, 끝나면 알림으로 알려 드려요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: Recording page

/// Shown for the meeting being recorded: time, meters, controls, the user's memo and bookmarks.
struct RecordingPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: RecordingSession
    @ObservedObject private var store = AppModel.shared.store
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                RecordingDot(paused: session.paused)
                Text(clock(Double(session.elapsed))).font(.system(size: 34, weight: .semibold, design: .monospaced))
                Tag(text: session.paused ? "일시정지됨" : "녹음 중", color: session.paused ? .yellow : .red)
                Tag(text: store.recordingMode == .liveTranslation ? "실시간 번역 켜짐" : "녹음 중",
                    color: store.recordingMode == .liveTranslation ? .blue : .gray)
                if let flash = session.flash { Text(flash).font(.caption).foregroundStyle(Color.brandText) }
                Spacer(minLength: 12)
                if store.recordingMode == .liveTranslation {
                    Button { model.toggleLiveOverlay() } label: {
                        Label(model.liveOverlayExpanded ? "미니 창 접기" : "상단에 띄우기",
                              systemImage: model.liveOverlayExpanded ? "rectangle.compress.vertical" : "rectangle.on.rectangle")
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("실시간 노트를 다른 앱 위에 작은 창으로 표시합니다")
                }
                Button { model.addBookmark() } label: { Label("북마크", systemImage: "flag") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(session.paused)
                    .help("지금 시점을 표시해 두면 나중에 그 부분부터 다시 들을 수 있어요 (⌘⇧B)")
                Button { model.togglePause() } label: {
                    Label(session.paused ? "재개" : "일시정지", systemImage: session.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PillButtonStyle())
                .help("일시정지하는 동안에는 마이크와 회의 소리를 녹음하지 않아요 (⌘⇧P)")
                Button { model.stopMeeting() } label: { Label("종료", systemImage: "stop.fill") }
                    .buttonStyle(PillButtonStyle(kind: .danger))
                    .help("녹음을 끝내고 전사를 시작합니다 (⌘N)")
            }
            LevelBars(levels: session.levels, paused: session.paused).frame(maxWidth: 420)
            warnings
            if store.recordingMode == .liveTranslation {
                LiveNotesView(snapshot: store.live?.meeting_id == meeting.id ? store.live : nil,
                              error: store.liveError, paused: session.paused)
            } else {
                Callout(symbol: "text.bubble", tint: .blue,
                        text: "영어 대화를 지금부터 전사하고 한국어로 번역해요. 녹음은 계속 저장됩니다.") {
                    Button(store.busy ? "켜는 중…" : "실시간 번역 켜기") { model.enableLiveTranslation() }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(store.busy)
                        .accessibilityIdentifier("enableLiveTranslation")
                }
                if let liveError = store.liveError {
                    Text(liveError).font(.caption).foregroundStyle(.red)
                }
            }
            MemoEditor(model: model, meetingID: meeting.id, initial: meeting.memo ?? "",
                       placeholder: "회의 중에 적어 둘 내용을 쓰세요. 노트 옆에 함께 저장돼요.")
            BookmarkList(bookmarks: meeting.bookmarks ?? [], seek: nil) { index in
                Task { await model.store.deleteBookmark(meetingID: meeting.id, index: index) }
            }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if session.callEnded {
            Callout(symbol: "phone.down", tint: .orange, text: UserDefaults.standard.bool(forKey: RecordingPrefs.autoStopAfterCall)
                    ? "통화가 끝난 것 같아요. 1분 안에 통화가 다시 시작되지 않으면 녹음을 자동으로 끝내요."
                    : "통화가 끝난 것 같아요. 녹음을 끝낼까요?") {
                Button("계속 녹음") { model.keepRecording() }.buttonStyle(PillButtonStyle(compact: true))
                Button("종료") { model.stopMeeting() }.buttonStyle(PillButtonStyle(kind: .danger, compact: true))
            }
        }
        if let problem = session.deviceProblem {
            Callout(symbol: "exclamationmark.triangle", tint: .red, text: "오디오 장치를 다시 열지 못했어요. 장치를 다시 연결하면 이어서 녹음해요. (\(problem))") { EmptyView() }
        } else if session.noInput {
            Callout(symbol: "speaker.slash", tint: .orange,
                    text: "마이크와 회의 소리가 모두 들어오지 않아요. 입력 장치와 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 화면 및 시스템 오디오 녹음을 확인하세요.") {
                Button("시스템 설정 열기") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                .buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}

struct Callout<Actions: View>: View {
    let symbol: String
    let tint: TagColor
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint.text).accessibilityHidden(true)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(tint.fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The user's own notes for a meeting, saved to the worker a moment after typing stops.
struct MemoEditor: View {
    @ObservedObject var model: AppModel
    let meetingID: String
    let initial: String
    var placeholder = "이 회의에 대해 따로 적어 둘 내용을 쓰세요."
    @State private var text = ""
    @State private var loaded: String?
    @State private var saved = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("내 메모").font(.exTitle)
                Spacer()
                if loaded != nil, text != saved {
                    Text("저장 중…").font(.caption).foregroundStyle(.tertiary)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .disabled(model.store.stoppingForUpdate)
                    .font(.exBody)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                if text.isEmpty {
                    Text(placeholder).font(.exBody).foregroundStyle(.tertiary).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                }
            }
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
        }
        .onAppear(perform: load)
        .onChange(of: meetingID) { _, _ in load() }
        .onChange(of: text) { _, value in
            if loaded == meetingID, value != saved { model.store.stageMemo(meetingID: meetingID, text: value) }
        }
        .task(id: text) {
            guard loaded == meetingID, text != saved else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await save()
        }
        .onDisappear { if text != saved { let id = meetingID, value = text; Task { await model.store.saveMemo(meetingID: id, text: value) } } }
    }

    private func load() {
        guard loaded != meetingID else { return }
        text = initial
        saved = initial
        loaded = meetingID
    }

    private func save() async {
        let value = text
        await model.store.saveMemo(meetingID: meetingID, text: value)
        saved = value
    }
}

struct BookmarkList: View {
    let bookmarks: [Bookmark]
    let seek: ((Double) -> Void)?
    var delete: ((Int) -> Void)? = nil

    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("북마크 \(bookmarks.count)").font(.exTitle)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(bookmarks.enumerated()), id: \.offset) { index, mark in
                        HStack(spacing: 10) {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(TagColor.orange.text).accessibilityHidden(true)
                            if let seek {
                                Button(clock(mark.time)) { seek(mark.time) }.buttonStyle(.plain).font(.exTimecode).foregroundStyle(Color.brandText)
                                    .help("여기부터 재생")
                            } else {
                                Text(clock(mark.time)).font(.exTimecode)
                            }
                            if !mark.note.isEmpty { Text(mark.note).font(.exBody) }
                            Spacer()
                            if let delete {
                                Button { delete(index) } label: { Image(systemName: "xmark").font(.caption) }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("북마크 삭제")
                            }
                        }
                        .hoverRow()
                    }
                }
            }
        }
    }
}

// MARK: Window access

/// Hands the hosting NSWindow to AppModel, so the menu bar and notifications can bring it forward.
struct MainWindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { attach(view.window) }
    }

    private func attach(_ window: NSWindow?) {
        guard let window, model.mainWindow !== window else { return }
        model.mainWindow = window
        if model.hideMainWindowOnce {
            // Opened at login: stay in the menu bar until the user needs the window.
            model.hideMainWindowOnce = false
            window.close()
        }
    }
}
