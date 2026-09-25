import AppKit
import EventKit
import SwiftUI

struct HomeView: View {
    @ObservedObject var meetings: MeetingStore
    @ObservedObject var calendar: UpcomingMeetingsStore
    @ObservedObject var detector: MeetingDetector
    let recent: [MeetingListItem]
    let open: (Route) -> Void
    let startMeeting: (String?) -> Void
    let importFile: () -> Void
    @State private var dismissedSignal: String?
    @ObservedObject private var login = AppModel.shared.login
    @AppStorage(RecordingPrefs.loginPromptDismissed) private var loginPromptDismissed = false
    @AppStorage(DisplayName.key) private var savedDisplayName = ""

    var body: some View {
        PageContainer {
            VStack(alignment: .leading, spacing: 6) {
                Text(welcome)
                    .font(.exDisplay).tracking(Font.displayTracking)
                Text("새 회의를 녹음하거나 지난 기록을 열어보세요.")
                    .font(.app(size: 12)).foregroundStyle(.secondary)
            }

            if let signal = detector.active, !meetings.recording, dismissedSignal != signal.name {
                // A Notion-style callout: the one tinted block, because it asks for an action now.
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(TagColor.blue.text)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(signal.name)에서 통화 중이에요").font(.app(size: 14, weight: .semibold))
                        Text("녹음을 시작한 뒤 화면에서 실시간 번역을 켤 수 있어요.")
                            .font(.app(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button { startMeeting(nil) } label: { Label("녹음 시작", systemImage: "record.circle") }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(meetings.busy)
                    Button { dismissedSignal = signal.name } label: { Label("알림 닫기", systemImage: "xmark").labelStyle(.iconOnly) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("닫기")
                }
                .padding(14)
                .background(TagColor.blue.fill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !login.enabled, !login.needsApproval, !loginPromptDismissed {
                Callout(symbol: "bell.badge", tint: .gray,
                        text: "Mac에 로그인할 때 Exanote를 메뉴 막대에 띄워 두면, 회의 앱이 마이크를 쓰기 시작할 때 알림으로 녹음을 제안해요.") {
                    Button("켜기") { login.set(true) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    Button { loginPromptDismissed = true } label: { Label("닫기", systemImage: "xmark").labelStyle(.iconOnly) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("닫기")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "다가올 회의") { calendarStatus }
                upcoming
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "최근 7일") { EmptyView() }
                WeekChart(items: recent)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "최근 회의") {
                    if !recent.isEmpty { ViewAllButton { open(.meetings) } }
                }
                if recent.isEmpty {
                    InlineNote(symbol: "text.bubble", text: "아직 기록된 회의가 없어요. 오른쪽 위의 녹음 시작(⌘N)을 누르거나 오디오 파일을 이 창으로 끌어다 놓으세요.") {
                        Button(action: importFile) { Label("파일 가져오기", systemImage: "square.and.arrow.down") }
                            .buttonStyle(PillButtonStyle(compact: true))
                    }
                } else {
                    MeetingList(items: Array(recent.prefix(5)), open: open)
                }
            }

            if let error = meetings.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.app(size: 12))
                    .foregroundStyle(Color.recording)
                    .textSelection(.enabled)
            }
        }
        .task {
            // Keeps "n분 후" badges and the 24-hour window current.
            while !Task.isCancelled {
                calendar.reload()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var welcome: String {
        let name = DisplayName.greeting(savedDisplayName)
        return name.isEmpty ? "어서 오세요." : "어서 오세요, \(name)님."
    }

    @ViewBuilder
    private var calendarStatus: some View {
        if calendar.access == .fullAccess {
            HStack(spacing: 8) {
                Tag(text: "macOS 캘린더 연결됨", color: .green)
                Button { calendar.reload() } label: { Label("캘린더 새로고침", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("캘린더 새로고침")
            }
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        switch calendar.access {
        case .fullAccess:
            if calendar.meetings.isEmpty {
                InlineNote(symbol: "calendar", text: "24시간 안에 예정된 회의가 없어요.") { EmptyView() }
            } else {
                VStack(spacing: 2) {
                    ForEach(calendar.meetings) { item in
                        UpcomingRow(meeting: item, disabled: meetings.recording || meetings.busy) { startMeeting(item.title) }
                    }
                }
            }
        case .notDetermined:
            InlineNote(symbol: "calendar.badge.plus", text: calendar.error ?? "macOS 캘린더에 추가된 Google·iCloud 일정을 읽어요. 일정은 이 Mac 밖으로 나가지 않아요.") {
                Button { Task { await calendar.connect() } } label: { Label(calendar.connecting ? "연결 중…" : "캘린더 연결", systemImage: "calendar") }
                    .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                    .disabled(calendar.connecting)
            }
        default:
            InlineNote(symbol: "calendar.badge.exclamationmark", text: "캘린더 접근이 꺼져 있어요. 시스템 설정에서 Exanote의 전체 접근을 허용하세요.") {
                Button("시스템 설정 열기") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}

/// A one-line gray note with an optional action, used instead of a boxed empty state.
struct InlineNote<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tertiary).frame(width: 20).accessibilityHidden(true)
            Text(text).font(.app(size: 13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            action
        }
        .padding(.vertical, 8)
    }
}

private struct UpcomingRow: View {
    let meeting: UpcomingMeeting
    let disabled: Bool
    let start: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.start.formatted(date: .omitted, time: .shortened)).font(.exData)
                Text(Calendar.current.isDateInToday(meeting.start) ? meeting.end.formatted(date: .omitted, time: .shortened) : "내일")
                    .font(.exDataSmall).foregroundStyle(.secondary)
            }
            .frame(width: 64, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(badge == nil ? TagColor.gray.fill : TagColor.blue.solid)
                .frame(width: 3, height: 30)
                .accessibilityHidden(true)

            Text(meeting.title).font(.exHeadline).lineLimit(1)
            if let badge { Tag(text: badge, color: .blue) }
            Tag(text: meeting.calendar)

            Spacer(minLength: 12)

            if let url = meeting.joinURL {
                Link(destination: url) { Label("참여", systemImage: "video") }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help(url.host ?? "")
            }
            Button { start() } label: { Label("녹음 시작", systemImage: "record.circle") }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                .disabled(disabled)
                .help("이 일정 이름으로 바로 녹음을 시작합니다")
        }
        .hoverRow()
        .accessibilityElement(children: .contain)
    }

    private var badge: String? {
        let now = Date()
        if meeting.start <= now { return "진행 중" }
        let minutes = Int(meeting.start.timeIntervalSince(now) / 60)
        return minutes <= 15 ? (minutes <= 0 ? "곧 시작" : "\(minutes)분 후") : nil
    }
}
