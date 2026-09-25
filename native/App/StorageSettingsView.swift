import AppKit
import EventKit
import SwiftUI

/// The pages of Settings, grouped in the page's own list as in Aside.
enum SettingsTab: Int, CaseIterable, Hashable {
    case general, recording, permissions, calendar, sync, aiTools, models

    var title: String {
        switch self {
        case .general: "일반"
        case .recording: "녹음"
        case .permissions: "권한"
        case .calendar: "캘린더"
        case .sync: "동기화"
        case .aiTools: "AI 도구"
        case .models: "AI 모델"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .permissions: "lock.shield"
        case .calendar: "calendar"
        case .sync: "arrow.triangle.2.circlepath"
        case .aiTools: "sparkles"
        case .models: "cpu"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "표시 이름, 화면과 처음 설정"
        case .recording: "회의 감지와 녹음하는 동안의 동작"
        case .permissions: "녹음에 필요한 macOS 권한"
        case .calendar: "다가올 회의를 홈에 보여 줘요"
        case .sync: "다른 Mac, 팀과 회의 노트를 나눠요"
        case .aiTools: "Claude Code, Codex가 회의 노트를 읽게 해요"
        case .models: "이 Mac에서 실행하는 모델과 저장 공간"
        }
    }

    /// Extra words the settings search matches.
    var keywords: String {
        switch self {
        case .general: "이름 표시 이름 프로필 테마 다크 라이트 화면 온보딩 처음 업데이트 update 글자 글꼴 폰트 크기 사이드바 font size"
        case .recording: "감지 알림 로그인 자동 종료 단축키 녹음 상태"
        case .permissions: "마이크 시스템 오디오 소리 알림 권한"
        case .calendar: "캘린더 일정 google icloud"
        case .sync: "icloud google drive 팀 공유 저장 위치"
        case .aiTools: "mcp claude codex cursor"
        case .models: "모델 다운로드 삭제 저장 공간 제거 uninstall"
        }
    }

    static let groups: [(title: String, tabs: [SettingsTab])] = [
        ("개인", [.general, .recording, .permissions]),
        ("연결", [.calendar, .sync, .aiTools]),
        ("이 Mac", [.models]),
    ]
}

/// Settings as a page of the main window: a searchable list of pages and the selected page.
struct SettingsPage: View {
    let tab: SettingsTab
    let select: (SettingsTab) -> Void
    let model: AppModel
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var calendar: UpcomingMeetingsStore

    var body: some View {
        HStack(spacing: 0) {
            SettingsNav(tab: tab, select: select, permissions: model.permissions, models: model.models, workspace: workspace)
                .frame(width: 216)
            Rectangle().fill(Color.hairline).frame(width: 1).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tab.title).font(.exDisplay).tracking(Font.displayTracking)
                        Text(tab.subtitle).font(.app(size: 12)).foregroundStyle(.secondary)
                    }
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity)
            }
            .id(tab)
        }
        .background(Color.canvas)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .recording: RecordingSettingsView(login: model.login)
        case .permissions: PermissionsSettingsView(permissions: model.permissions)
        case .calendar: CalendarSection(calendar: calendar)
        case .sync: SyncSettingsView(workspace: workspace)
        case .aiTools: AIConnectionsSection(title: nil)
        case .models: ModelSettingsView(store: model.models)
        }
    }
}

private struct SettingsNav: View {
    let tab: SettingsTab
    let select: (SettingsTab) -> Void
    @ObservedObject var permissions: SystemPermissions
    @ObservedObject var models: ModelStore
    @ObservedObject var workspace: WorkspaceStore
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("설정 검색", text: $query).textFieldStyle(.plain)
                    .onSubmit { if let first = matches.first { select(first) } }
            }
            .font(.app(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(SettingsTab.groups, id: \.title) { group in
                        let tabs = group.tabs.filter(matches.contains)
                        if !tabs.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.app(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.bottom, 4)
                                ForEach(tabs, id: \.self) { item($0) }
                            }
                        }
                    }
                    if matches.isEmpty {
                        Text("일치하는 설정이 없어요").font(.app(size: 12.5)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
    }

    private var matches: [SettingsTab] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter { ($0.title + " " + $0.keywords).lowercased().contains(text) }
    }

    private func item(_ item: SettingsTab) -> some View {
        let selected = item == tab
        return Button { select(item) } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.app(size: 13.5, weight: selected ? .semibold : .regular))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Text(item.title).font(.app(size: 13.5, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if let badge = badge(item) {
                    Text(badge)
                        .font(.app(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.recording)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.recording.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Color.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// What still needs the user, shown next to the page that fixes it.
    private func badge(_ item: SettingsTab) -> String? {
        switch item {
        case .permissions: permissions.recordingReady ? nil : "필요"
        case .models: models.overview == nil || models.missing.isEmpty ? nil : "설치"
        case .sync: workspace.overview?.status.error == nil ? nil : "문제"
        default: nil
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(RecordingPrefs.onboarded) private var onboarded = true
    @AppStorage(RecordingPrefs.checklistDismissed) private var checklistDismissed = false
    @AppStorage(DisplayName.key) private var savedDisplayName = ""
    @State private var editingDisplayName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("내 정보") {
                SettingsRow(symbol: "person.crop.circle", title: "표시 이름", detail: DisplayName.resolved(savedDisplayName)) {
                    Button("변경") { editingDisplayName = true }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }

            SettingsSection("화면") {
                SettingsRow(symbol: "circle.lefthalf.filled", title: "테마", detail: "시스템을 고르면 macOS 설정을 따라가요") {
                    Picker("테마", selection: $appearance) {
                        Text("시스템").tag("system")
                        Text("라이트").tag("light")
                        Text("다크").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("처음 설정") {
                SettingsRow(symbol: "sparkles.rectangle.stack", title: "처음 설정 다시 보기", detail: "권한, 모델, 캘린더, 회의 감지를 순서대로 다시 확인해요") {
                    Button("시작") {
                        checklistDismissed = false
                        onboarded = false
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                }
            }

            TypographySettings()

            UpdateSettings()

            SettingsSection("정보") {
                SettingsRow(symbol: "info.circle", title: "Exanote \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",
                            detail: "모든 처리는 이 Mac에서 해요. 오디오와 전사는 호스팅된 AI로 보내지 않아요.")
            }
        }
        .sheet(isPresented: $editingDisplayName) { DisplayNameEditor() }
    }
}

/// Settings ▸ 녹음: what happens around a meeting without the user opening the window.
struct RecordingSettingsView: View {
    @ObservedObject var login: LoginItem
    @ObservedObject private var notifier = Notifier.shared
    @AppStorage(RecordingPrefs.showPill) private var showPill = true
    @AppStorage(RecordingPrefs.autoStopAfterCall) private var autoStop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("회의 감지") {
                LoginItemRow(login: login)
            }

            SettingsSection("녹음하는 동안") {
                SettingsToggle(symbol: "capsule", title: "화면 위에 녹음 상태 표시",
                               detail: "다른 앱을 보고 있어도 경과 시간, 입력 레벨, 일시정지·북마크·종료 버튼이 보여요. 끌어서 옮길 수 있어요.",
                               isOn: $showPill)
                SettingsToggle(symbol: "phone.down", title: "통화가 끝나면 자동으로 녹음 종료",
                               detail: "회의 앱이 마이크를 놓은 뒤 1분 넘게 다시 쓰지 않으면 녹음을 끝내요. 끄면 알림만 보내요.",
                               isOn: $autoStop)
                SettingsRow(symbol: "keyboard", title: "단축키", detail: "녹음 ⌘N · 일시정지 ⌘⇧P · 북마크 ⌘⇧B")
            }
        }
        .onAppear { login.refresh() }
        .task { await notifier.refreshAuthorization() }
    }
}

struct LoginItemRow: View {
    @ObservedObject var login: LoginItem

    var body: some View {
        SettingsToggle(symbol: "power", title: "Mac에 로그인하면 Exanote 열기",
                       detail: login.needsApproval ? "시스템 설정 ▸ 일반 ▸ 로그인 항목에서 Exanote를 허용해 주세요"
                           : login.error ?? "메뉴 막대에서 조용히 실행돼 첫 회의부터 감지해요. 창은 열리지 않아요.",
                       isOn: Binding(get: { login.enabled || login.needsApproval }, set: { login.set($0) }))
        if login.needsApproval {
            SettingsRow(title: "로그인 항목 허용이 필요해요") {
                Button("열기") { login.openSystemSettings() }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}

/// Microphone, system audio and (optionally) notifications, with what to do about each.
struct PermissionsSection: View {
    @ObservedObject var permissions: SystemPermissions
    @ObservedObject private var notifier = Notifier.shared
    var title: String? = "녹음"
    var includeNotifications = true
    @AppStorage(RecordingPrefs.notifyOnDetection) private var notifyOnDetection = true

    var body: some View {
        SettingsSection(title) {
            SettingsRow(symbol: "mic", title: "마이크", detail: "내 목소리를 녹음해요") {
                state(permissions.microphone) { Task { await permissions.requestMicrophone() } }
            }
            SettingsRow(symbol: "speaker.wave.2", title: "시스템 오디오", detail: "회의 앱에서 나오는 상대방 목소리를 녹음해요. 화면은 녹화하지 않아요.") {
                state(permissions.systemAudio) { Task { await permissions.requestSystemAudio() } }
            }
            if includeNotifications {
                SettingsRow(symbol: "bell", title: "macOS 알림 권한", detail: notifier.authorized == true ? "Exanote가 이 Mac에 알림을 표시할 수 있어요" : "회의 녹음 제안과 노트 완성 알림을 받으려면 허용해 주세요") {
                    if notifier.authorized == true {
                        SetupState(kind: .done("허용됨"))
                    } else {
                        SetupState(kind: .action(notifier.undecided ? "허용" : "시스템 설정 열기") {
                            Task { await notifier.requestAuthorization() }
                        })
                    }
                }
                SettingsToggle(symbol: "bell.badge", title: "회의 감지 시 녹음 제안",
                               detail: notifier.authorized == true
                                   ? "통화를 감지하면 녹음할지 물어봐요. 꺼도 노트 완성 알림은 받아요."
                                   : "위의 macOS 알림 권한을 먼저 허용해 주세요",
                               isOn: Binding(get: { notifier.authorized == true && notifyOnDetection },
                                             set: { notifyOnDetection = $0 }))
                    .disabled(notifier.authorized != true)
            }
        }
        .task { await permissions.watch() }
        .task { await notifier.refreshAuthorization() }
    }

    private func state(_ status: SystemPermissions.Status, request: @escaping () -> Void) -> SetupState {
        switch status {
        case .granted: SetupState(kind: .done("허용됨"))
        case .notAsked: SetupState(kind: .action("허용", request))
        case .denied: SetupState(kind: .action("시스템 설정 열기", request))
        case .unknown: SetupState(kind: .action("확인", request))
        }
    }
}

struct PermissionsSettingsView: View {
    let permissions: SystemPermissions

    var body: some View {
        PermissionsSection(permissions: permissions, title: nil)
        SettingsSection(footer: "허용을 한 번 거절하면 macOS에서는 시스템 설정에서만 다시 켤 수 있어요. 켠 뒤 이 화면으로 돌아오면 바로 반영돼요.") {
            SettingsRow(symbol: "gear", title: "개인정보 보호 및 보안", detail: "마이크와 화면 및 시스템 오디오 녹음 목록에서 Exanote를 켜요") {
                Button("시스템 설정 열기") { SystemPermissions.open("Privacy_Microphone") }
                    .buttonStyle(PillButtonStyle(compact: true))
            }
        }
    }
}

struct CalendarSection: View {
    @ObservedObject var calendar: UpcomingMeetingsStore
    var title: String? = nil

    var body: some View {
        SettingsSection(title, footer: "Google 캘린더는 시스템 설정 ▸ 인터넷 계정에서 Google 계정을 추가하면 함께 표시돼요. 일정은 이 Mac 밖으로 나가지 않아요.") {
            SettingsRow(symbol: "calendar", title: "macOS 캘린더", detail: detail) {
                switch calendar.access {
                case .fullAccess:
                    SetupState(kind: .done("연결됨"))
                case .notDetermined:
                    Button(calendar.connecting ? "연결 중…" : "연결") { Task { await calendar.connect() } }
                        .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
                        .disabled(calendar.connecting)
                default:
                    Button("시스템 설정 열기") { SystemPermissions.open("Privacy_Calendars") }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            if let error = calendar.error {
                SettingsRow(symbol: "exclamationmark.triangle", title: "캘린더 연결 확인", detail: error) {
                    Button("시스템 설정 열기") { SystemPermissions.open("Privacy_Calendars") }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
        }
    }

    private var detail: String {
        switch calendar.access {
        case .fullAccess: calendar.meetings.isEmpty ? "앞으로 24시간 안에 잡힌 회의가 없어요" : "앞으로 24시간 안에 회의 \(calendar.meetings.count)개"
        case .notDetermined: "다가올 회의를 홈에 보여 주고, 일정 이름으로 녹음을 시작해요"
        default: "캘린더 접근이 꺼져 있어요. 시스템 설정에서 Exanote의 전체 접근을 허용하세요"
        }
    }
}

struct SyncSettingsView: View {
    @ObservedObject var workspace: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SyncLocationSection(workspace: workspace)
            TeamSection(workspace: workspace)
        }
    }
}

/// Where meeting notes are copied: this Mac only, iCloud Drive, Google Drive or a team folder.
struct SyncLocationSection: View {
    @ObservedObject var workspace: WorkspaceStore
    var title: String? = "저장 위치"

    private var choices: [WorkspaceOption] {
        workspace.overview?.options.filter { $0.kind != "local" } ?? []
    }

    var body: some View {
        SettingsSection(title, footer: "오디오는 이 Mac에만 남고, 전사와 요약만 선택한 폴더의 'Exanote'에 복사돼요. 실제 동기화는 iCloud Drive나 Google Drive가 해요.") {
            option(path: "", symbol: "laptopcomputer", title: "이 Mac만", detail: "다른 기기나 팀과 공유하지 않아요")
            ForEach(choices) { item in
                option(path: item.path, symbol: item.symbol, title: item.name,
                       detail: item.kind == "icloud" ? item.purpose : "\(item.purpose) · \(item.account)")
            }
            if workspace.googleDriveInstalled {
                SettingsRow(symbol: "externaldrive", title: "Google Drive 폴더 접근", detail: "팀 폴더가 보이지 않으면 Google Drive 폴더를 선택해요") {
                    Button("폴더 선택") { Task { await workspace.connectGoogleDriveFolder() } }
                        .buttonStyle(PillButtonStyle(compact: true))
                }
            }
            if let error = workspace.overview?.status.error ?? workspace.error {
                ErrorLine(text: error)
            } else if workspace.selected != nil, let last = workspace.overview?.status.last_sync.flatMap(parseISODate) {
                SettingsRow(symbol: "checkmark.icloud", title: "마지막 저장 \(last.formatted(.relative(presentation: .named)))")
            }
        }
        .task { await workspace.refresh() }
    }

    private func option(path: String, symbol: String, title: String, detail: String) -> some View {
        let selected = (workspace.selected?.path ?? "") == path
        return Button { Task { await workspace.choose(path.isEmpty ? nil : path) } } label: {
            SettingsRow(symbol: symbol, title: title, detail: detail) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.app(size: 17))
                    .foregroundStyle(selected ? Color.brandText : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
