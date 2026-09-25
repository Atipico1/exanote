import AppKit
import SwiftUI

/// First-run setup, modeled on Smooth's: one thing per screen, the next screen as soon as the
/// current one is done, and "나중에 할래요" wherever a step is optional.
struct OnboardingView: View {
    let model: AppModel
    let finish: () -> Void
    @ObservedObject var permissions: SystemPermissions
    @ObservedObject var models: ModelStore
    @ObservedObject var calendar: UpcomingMeetingsStore
    @ObservedObject var login: LoginItem
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject private var notifier = Notifier.shared
    @AppStorage(DisplayName.key) private var savedDisplayName = ""
    @State private var step: Step = .permissions

    init(model: AppModel, finish: @escaping () -> Void) {
        self.model = model
        self.finish = finish
        permissions = model.permissions
        models = model.models
        calendar = model.calendar
        login = model.login
        workspace = model.workspace
    }

    enum Step: Int, CaseIterable {
        case permissions, models, calendar, detection, connect
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                LogoMark(size: 24)
                Wordmark(size: 16)
                Spacer()
                Button("건너뛰기", action: finish)
                    .buttonStyle(.plain)
                    .font(.app(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("처음 설정은 설정 ▸ 일반에서 다시 볼 수 있어요")
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    progress
                    header
                    content
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
                .id(step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }

            actions
                .frame(maxWidth: 540)
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
        }
        .background(Color.canvas.ignoresSafeArea())
        .task(id: step) { await autoAdvance() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Color.brandText : Color.hairline)
                    .frame(width: item == step ? 22 : 8, height: 6)
            }
            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.app(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Step.allCases.count)단계 중 \(step.rawValue + 1)단계")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.app(size: 26, weight: .semibold)).tracking(-0.6)
            Text(message)
                .font(.app(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firstName: String {
        let name = DisplayName.greeting(savedDisplayName)
        return name.isEmpty ? "" : "\(name)님, "
    }

    private var title: String {
        switch step {
        case .permissions: "\(firstName)반가워요"
        case .models: "AI 모델을 받을게요"
        case .calendar: "다가올 회의를 챙겨 드릴까요?"
        case .detection: "회의를 놓치지 않게 할게요"
        case .connect: "노트를 어디서 볼까요?"
        }
    }

    private var message: String {
        switch step {
        case .permissions:
            "Exanote는 회의를 이 Mac 안에서만 받아 적어요. 내 목소리와 상대방 목소리를 들을 수 있게 두 가지를 허용해 주세요. 둘 다 허용되면 바로 다음으로 넘어가요."
        case .models:
            "받아 적기, 화자 구분, 단어 시간 맞춤, 요약을 하는 모델 네 개예요. 한 번 받으면 인터넷 없이도 동작해요. 받는 동안 다음 단계를 진행해도 돼요."
        case .calendar:
            "macOS 캘린더를 연결하면 곧 시작할 회의가 홈에 보이고, 녹음에 일정 이름이 붙어요."
        case .detection:
            "Mac에 로그인할 때 Exanote가 메뉴 막대에서 조용히 켜지고, 회의 앱이 마이크를 쓰기 시작하면 알림으로 녹음을 제안해요. 녹음은 알림을 눌러야 시작돼요."
        case .connect:
            "다른 Mac이나 팀과 나누려면 저장 위치를 고르세요. Claude Code나 Codex를 연결하면 AI에게 회의 내용을 물어볼 수 있어요. 둘 다 나중에 설정에서 바꿀 수 있어요."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permissions:
            PermissionsSection(permissions: permissions, title: nil, includeNotifications: false)
            Button("시스템 오디오 허용이 잘 안 되나요?") { SystemPermissions.open("Privacy_ScreenCapture") }
                .buttonStyle(.plain)
                .font(.app(size: 12.5))
                .foregroundStyle(.secondary)
                .underline()
                .frame(maxWidth: .infinity)
        case .models:
            ModelListSection(store: models, title: nil, footer: modelFooter)
        case .calendar:
            CalendarSection(calendar: calendar)
        case .detection:
            SettingsSection {
                LoginItemRow(login: login)
                SettingsRow(symbol: "bell.badge", title: "알림", detail: "회의가 시작되거나 노트가 준비되면 알려요") {
                    if notifier.authorized == true {
                        SetupState(kind: .done("허용됨"))
                    } else {
                        SetupState(kind: .action(notifier.undecided ? "허용" : "시스템 설정 열기") {
                            Task { await notifier.requestAuthorization() }
                        })
                    }
                }
            }
            .task { await notifier.refreshAuthorization() }
        case .connect:
            SyncLocationSection(workspace: workspace)
            AIConnectionsSection(title: "AI 도구")
        }
    }

    private var modelFooter: String? {
        guard let overview = models.overview else { return nil }
        let left = overview.models.filter { !$0.installed }.reduce(Int64(0)) { $0 + max(0, $1.expected_bytes - ($1.downloading ? $1.bytes : 0)) }
        return left > 0 ? "남은 다운로드 약 \(formatBytes(left)). 모델은 ~/.local/share/exanote/models에 저장돼요." : "모든 모델이 준비됐어요."
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if step != .permissions {
                Button { go(-1) } label: { Label("이전", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle(kind: .quiet))
            }
            Spacer()
            if step != .connect && !stepDone {
                Button("나중에 할래요") { go(1) }
                    .buttonStyle(.plain)
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            primary
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch step {
        case .permissions where !permissions.recordingReady:
            Button("허용하기") {
                Task {
                    if permissions.microphone != .granted { await permissions.requestMicrophone() }
                    if permissions.systemAudio != .granted && permissions.systemAudio != .unknown { await permissions.requestSystemAudio() }
                }
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
        case .models where !models.missing.isEmpty:
            Button("모두 받기") { Task { await models.install(models.missing.map(\.id)) } }
                .buttonStyle(PillButtonStyle(kind: .primary))
        case .models where models.models.contains(where: \.downloading):
            Button("받는 동안 계속하기") { go(1) }.buttonStyle(PillButtonStyle(kind: .primary))
        case .calendar where calendar.access == .notDetermined:
            Button("캘린더 연결") { Task { await calendar.connect() } }.buttonStyle(PillButtonStyle(kind: .primary))
        case .connect:
            Button("Exanote 시작하기", action: finish).buttonStyle(PillButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        default:
            Button("계속") { go(1) }.buttonStyle(PillButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
    }

    /// Whether the current step needs nothing more from the user.
    private var stepDone: Bool {
        switch step {
        case .permissions: permissions.recordingReady
        case .models: models.overview != nil && !models.models.isEmpty && models.models.allSatisfy(\.installed)
        case .calendar: calendar.access == .fullAccess
        case .detection: (login.enabled || login.needsApproval) && notifier.authorized == true
        case .connect: false
        }
    }

    /// Like Smooth: a finished step moves on by itself after a short beat. The detection and
    /// connection steps wait for the user, since both are choices rather than requirements.
    private func autoAdvance() async {
        guard [.permissions, .models, .calendar].contains(step) else { return }
        while !Task.isCancelled {
            if stepDone {
                try? await Task.sleep(for: .milliseconds(550))
                if !Task.isCancelled && stepDone { go(1) }
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func go(_ offset: Int) {
        guard let next = Step(rawValue: step.rawValue + offset) else { return }
        withAnimation(.easeOut(duration: 0.25)) { step = next }
    }
}

/// Sidebar card until setup is complete, as Smooth keeps a checklist until every item is done.
struct SetupChecklist: View {
    @ObservedObject var permissions: SystemPermissions
    @ObservedObject var models: ModelStore
    @ObservedObject var calendar: UpcomingMeetingsStore
    @ObservedObject var login: LoginItem
    @ObservedObject var workspace: WorkspaceStore
    let open: (SettingsTab) -> Void
    @AppStorage(RecordingPrefs.checklistDismissed) private var dismissed = false

    init(model: AppModel, open: @escaping (SettingsTab) -> Void) {
        permissions = model.permissions
        models = model.models
        calendar = model.calendar
        login = model.login
        workspace = model.workspace
        self.open = open
    }

    private struct Item: Identifiable {
        let id: SettingsTab
        let title: String
        let done: Bool
        var note: String? = nil
    }

    private var items: [Item] {
        let downloading = models.models.filter(\.downloading)
        let note = downloading.isEmpty ? nil : "\(Int((downloading.map(\.progress).reduce(0, +) / Double(downloading.count)) * 100))%"
        return [
            Item(id: .permissions, title: "녹음 권한 허용", done: permissions.recordingReady),
            Item(id: .models, title: "AI 모델 받기", done: models.overview != nil && models.missing.isEmpty && downloading.isEmpty, note: note),
            Item(id: .calendar, title: "캘린더 연결", done: calendar.access == .fullAccess),
            Item(id: .recording, title: "로그인할 때 자동 실행", done: login.enabled),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = workspace.overview?.status.error {
                Button { open(.sync) } label: {
                    Label { Text("동기화 문제").font(.app(size: 12.5, weight: .medium)) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.recording)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(error)
                .padding(.horizontal, 4)
            }
            let done = items.filter(\.done).count
            if !dismissed && models.overview != nil && done < items.count {
                card(done: done)
            }
        }
    }

    private func card(done: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("설정 마무리").font(.app(size: 12.5, weight: .semibold))
                Text("\(done)/\(items.count)").font(.app(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { dismissed = true } label: { Label("닫기", systemImage: "xmark").labelStyle(.iconOnly).font(.app(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("닫기. 설정에서 언제든 할 수 있어요")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline)
                    Capsule().fill(Color.brandText).frame(width: proxy.size.width * CGFloat(done) / CGFloat(items.count))
                }
            }
            .frame(height: 4)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button { open(item.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? Color.success : Color.secondary.opacity(0.6))
                            Text(item.title)
                                .strikethrough(item.done, color: .secondary)
                                .foregroundStyle(item.done ? Color.secondary : Color.primary)
                            Spacer()
                            if let note = item.note {
                                Text(note).font(.app(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                            } else if !item.done {
                                Image(systemName: "chevron.right").font(.app(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.app(size: 12.5))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.done)
                }
            }
        }
        .padding(12)
        .background(Color.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hairline))
    }
}
