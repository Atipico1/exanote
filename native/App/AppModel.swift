import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// User choices for recording and detection, shared by Settings, the monitor and the panel.
enum RecordingPrefs {
    static let notifyOnDetection = "notifyOnDetection"
    static let showPill = "showRecordingPill"
    static let autoStopAfterCall = "autoStopAfterCall"
    static let loginPromptDismissed = "loginPromptDismissed"
    /// Set when the first-run setup screens are finished or skipped.
    static let onboarded = "onboardingCompleted"
    static let checklistDismissed = "setupChecklistDismissed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [notifyOnDetection: true, showPill: true, autoStopAfterCall: true])
    }
}

@MainActor
final class LevelMeter: ObservableObject {
    @Published var microphone: Double = 0
    @Published var system: Double = 0

    /// RMS to a 0...1 bar over -60...0 dBFS, falling back slowly like a VU meter.
    func update(microphone mic: Float, system sys: Float) {
        microphone = max(Self.scale(mic), microphone * 0.75)
        system = max(Self.scale(sys), system * 0.75)
        if microphone < 0.01 { microphone = 0 }
        if system < 0.01 { system = 0 }
    }

    func reset() {
        microphone = 0
        system = 0
    }

    private static func scale(_ rms: Float) -> Double {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(rms)) + 60) / 60))
    }
}

/// The live state of this app's recording, for the toolbar, menu bar, floating panel and page.
/// Levels live in their own object so ten updates a second redraw only the meters.
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var meetingID: String?
    @Published private(set) var paused = false
    /// Whole seconds recorded; paused time is not counted, so bookmarks match transcript times.
    @Published private(set) var elapsed = 0
    /// Nothing at all reaches the recording (permission or device problem), not just a quiet room.
    @Published private(set) var noInput = false
    @Published private(set) var deviceProblem: String?
    @Published var callEnded = false
    @Published private(set) var flash: String?
    let levels = LevelMeter()
    private(set) var seconds: Double = 0
    private(set) var quietFor: Double = 0

    private let store: MeetingStore
    private var poll: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?

    init(store: MeetingStore) { self.store = store }

    var isActive: Bool { meetingID != nil }

    func begin(meetingID: String) {
        self.meetingID = meetingID
        paused = false
        elapsed = 0
        seconds = 0
        callEnded = false
        noInput = false
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func end() {
        poll?.cancel()
        poll = nil
        meetingID = nil
        paused = false
        elapsed = 0
        seconds = 0
        callEnded = false
        noInput = false
        deviceProblem = nil
        levels.reset()
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { levels.reset() }
    }

    func show(_ message: String) {
        flash = message
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    private func tick() {
        guard let snapshot = store.capture.snapshot() else { return }
        seconds = snapshot.seconds
        quietFor = snapshot.quietFor
        if Int(snapshot.seconds) != elapsed { elapsed = Int(snapshot.seconds) }
        if !paused { levels.update(microphone: snapshot.microphone, system: snapshot.system) }
        let dead = !paused && ((snapshot.seconds > 8 && snapshot.deadFor > 8) || snapshot.stalledFor > 8)
        if dead != noInput { noInput = dead }
        if store.capture.deviceProblem != deviceProblem { deviceProblem = store.capture.deviceProblem }
    }
}

/// Owns the app's stores and every way to start, pause, mark and stop a recording, so the window,
/// menu bar, floating panel and notifications all do the same thing.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = MeetingStore()
    let workspace = WorkspaceStore()
    let calendar = UpcomingMeetingsStore()
    let detector = MeetingDetector()
    let nav = Navigator()
    let actions = MeetingActions()
    let session: RecordingSession
    let login = LoginItem()
    let permissions = SystemPermissions()
    let models = ModelStore()
    let folders = FolderStore()

    @Published var missingPermission: RecordingPermission?
    @Published private(set) var liveOverlayExpanded = false
    /// Filled in by the main window so the menu bar and notifications can bring it back.
    var openMainWindow: (() -> Void)?
    weak var mainWindow: NSWindow?
    var hideMainWindowOnce = false

    private var launched = false
    private var cancellables = Set<AnyCancellable>()
    private var panel: RecordingPanelController?
    private var statuses: [String: String] = [:]

    // Detection and call-end bookkeeping, evaluated by monitor().
    private var signalSince: Date?
    private var signalLastSeen: Date?
    private var notifiedSignal: String?
    private var callSeenDuringRecording = false
    private var callLastSeen: Date?
    private var callEndNotified = false
    private var quietNotified = false

    private init() {
        session = RecordingSession(store: store)
        actions.attach(store: store, workspace: workspace, nav: nav)
        RecordingPrefs.registerDefaults()
    }

    func launch(atLogin: Bool) {
        guard !launched else { return }
        launched = true
        hideMainWindowOnce = atLogin
        Notifier.shared.setUp(model: self)
        panel = RecordingPanelController(model: self)
        Task { await store.start(); announceRecovered() }
        Task { await workspace.start() }
        Task { await detector.start() }
        Task { if calendar.access == .fullAccess { await calendar.connect() } }
        Task { await models.watch() }
        Task { await folders.load() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.permissions.refresh()
                self?.login.refresh()
                Task { await Notifier.shared.refreshAuthorization() }
            }
        }
        Task {
            while !Task.isCancelled {
                monitor()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        store.$meetings.sink { [weak self] in self?.meetingsChanged($0) }.store(in: &cancellables)
    }

    // MARK: Recording

    var canStart: Bool { !store.recording && !store.busy }

    func startMeeting(_ title: String? = nil) {
        guard canStart else { return }
        Task {
            guard canStart else { return }
            if let missing = await RecordingPermission.firstMissing() {
                missingPermission = missing
                showMain()
                return
            }
            // A title comes from an upcoming-meeting card; otherwise use the event happening now.
            let event = title == nil ? calendar.happeningNow() : calendar.meetings.first { $0.title == title }
            await store.startRecording(title: title, event: event)
            guard store.recording, let id = store.recordingID else {
                if store.error != nil { showMain() }
                return
            }
            Task { await folders.load() }
            session.begin(meetingID: id)
            callSeenDuringRecording = detector.active != nil
            callLastSeen = detector.active != nil ? Date() : nil
            callEndNotified = false
            quietNotified = false
            liveOverlayExpanded = false
            Notifier.shared.clear(.detected)
            nav.route = .local(id)
            showMain(route: .local(id))
        }
    }

    func enableLiveTranslation() {
        guard store.recording, store.recordingMode == .afterRecording else { return }
        Task { await store.enableLiveTranslation() }
    }

    func stopMeeting(automatically: Bool = false) {
        Task {
            guard store.recording, !store.busy else { return }
            let id = store.recordingID
            let title = store.meetings.first { $0.id == id }?.title
            await store.stopRecording()
            session.end()
            liveOverlayExpanded = false
            Notifier.shared.clear(.callEnded)
            Notifier.shared.clear(.quiet)
            if automatically {
                Notifier.shared.post(.stopped, title: "통화가 끝나 녹음을 마쳤어요",
                                     body: "\(title ?? "회의") 노트를 이 Mac에서 만들고 있어요.", meetingID: id)
            }
            if let id { nav.route = .local(id) }
        }
    }

    func togglePause() {
        guard store.recording else { return }
        if session.paused {
            store.resumeRecording()
            session.setPaused(store.capture.paused)
        } else {
            store.pauseRecording()
            session.setPaused(true)
        }
    }

    func toggleLiveOverlay() {
        guard session.isActive, store.recordingMode == .liveTranslation else { return }
        if !liveOverlayExpanded {
            UserDefaults.standard.set(true, forKey: RecordingPrefs.showPill)
        }
        liveOverlayExpanded.toggle()
    }

    func addBookmark() {
        guard store.recording, let id = store.recordingID else { return }
        let time = session.seconds
        session.show("북마크 \(clock(time))")
        Task { await store.addBookmark(meetingID: id, time: time) }
    }

    /// Keeps recording after "the call seems over"; waits for the next call to end.
    func keepRecording() {
        session.callEnded = false
        callSeenDuringRecording = false
        callLastSeen = nil
        Notifier.shared.clear(.callEnded)
    }

    func showMain(route: Route? = nil) {
        if let route { nav.route = route }
        NSApp.activate()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: Monitoring

    /// Meeting detection notices, "the call ended" and long silence, every two seconds.
    private func monitor() {
        let now = Date()
        let signal = detector.active
        if signal != nil {
            if signalSince == nil { signalSince = now }
            signalLastSeen = now
        } else {
            signalSince = nil
            // A call ended some time ago: the next one may notify again.
            if let last = signalLastSeen, now.timeIntervalSince(last) > 30 { notifiedSignal = nil }
        }

        if !store.recording {
            // Five seconds of a meeting app holding the microphone, once per call.
            if let signal, let since = signalSince, now.timeIntervalSince(since) >= 5, notifiedSignal != signal.bundleID {
                notifiedSignal = signal.bundleID
                if UserDefaults.standard.bool(forKey: RecordingPrefs.notifyOnDetection) {
                    let event = calendar.happeningNow()?.title
                    Notifier.shared.post(.detected, title: "\(signal.name)에서 회의 중인가요?",
                                         body: event.map { "‘\($0)’ 회의를 바로 녹음할 수 있어요." } ?? "누르면 녹음을 시작해요.")
                }
            }
            if signal == nil { Notifier.shared.clear(.detected) }
            return
        }

        guard session.isActive else { return }
        if signal != nil {
            callSeenDuringRecording = true
            callLastSeen = now
            if session.callEnded { session.callEnded = false }
            callEndNotified = false
            Notifier.shared.clear(.callEnded)
        } else if callSeenDuringRecording, let last = callLastSeen {
            let gone = now.timeIntervalSince(last)
            if gone >= 12 {
                if !session.callEnded { session.callEnded = true }
                if !callEndNotified {
                    callEndNotified = true
                    let auto = UserDefaults.standard.bool(forKey: RecordingPrefs.autoStopAfterCall)
                    Notifier.shared.post(.callEnded, title: "통화가 끝난 것 같아요",
                                         body: auto ? "1분 안에 다시 통화하지 않으면 녹음을 자동으로 끝내요." : "녹음을 끝내려면 누르세요.")
                }
                if UserDefaults.standard.bool(forKey: RecordingPrefs.autoStopAfterCall), gone >= 72 {
                    stopMeeting(automatically: true)
                    return
                }
            }
        }

        if session.quietFor >= 600, !quietNotified, !session.paused {
            quietNotified = true
            Notifier.shared.post(.quiet, title: "10분째 소리가 없어요", body: "회의가 끝났다면 누르면 녹음을 끝내요.")
        } else if session.quietFor < 5 {
            quietNotified = false
        }
    }

    private func announceRecovered() {
        guard let meeting = store.recovered else { return }
        Notifier.shared.post(.processed, title: "끊긴 녹음을 복구했어요",
                             body: "‘\(meeting.title)’은 앱이 예기치 않게 종료되기 전까지 녹음된 부분으로 노트를 만들어요.", meetingID: meeting.id)
        store.dismissRecovered()
    }

    private func meetingsChanged(_ meetings: [Meeting]) {
        let first = statuses.isEmpty
        for meeting in meetings {
            let before = statuses[meeting.id]
            statuses[meeting.id] = meeting.status
            guard !first, let before, ["queued", "processing"].contains(before), before != meeting.status else { continue }
            // Nobody needs a banner for the meeting already open in front of them.
            if NSApp.isActive, nav.route == .local(meeting.id), mainWindow?.isVisible == true { continue }
            if meeting.status == "done" {
                Notifier.shared.post(.processed, title: "회의 노트가 준비됐어요", body: meeting.title, meetingID: meeting.id)
            } else if meeting.status == "error" {
                Notifier.shared.post(.processed, title: "회의를 처리하지 못했어요", body: "\(meeting.title) · 다시 처리할 수 있어요.", meetingID: meeting.id)
            }
        }
    }

    // MARK: Quit

    func shouldTerminate() -> NSApplication.TerminateReply {
        guard store.recording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "녹음 중이에요"
        alert.informativeText = "지금까지 녹음한 부분을 저장하고 종료할까요? 전사와 요약은 앱을 다시 열지 않아도 이 Mac에서 계속 만들어요."
        alert.addButton(withTitle: "저장하고 종료")
        alert.addButton(withTitle: "취소")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            await store.stopRecording()
            session.end()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Launch at login through SMAppService, so detection is running before the first call of the day.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    var enabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func refresh() { status = SMAppService.mainApp.status }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// System notifications: a detected call, a call that ended, long silence and finished notes.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Kind: String {
        case detected, callEnded, quiet, stopped, processed

        var category: String { "exanote.\(rawValue)" }
    }

    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var authorized: Bool?
    @Published private(set) var undecided = false

    func setUp(model: AppModel) {
        self.model = model
        center.delegate = self
        let start = UNNotificationAction(identifier: "start", title: "녹음 시작", options: [])
        let stop = UNNotificationAction(identifier: "stop", title: "녹음 종료", options: [])
        let keep = UNNotificationAction(identifier: "keep", title: "계속 녹음", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.detected.category, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.callEnded.category, actions: [stop, keep], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.quiet.category, actions: [stop], intentIdentifiers: []),
        ])
        // Before setup is finished, onboarding asks at the step that explains why.
        Task {
            if UserDefaults.standard.bool(forKey: RecordingPrefs.onboarded) {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            await refreshAuthorization()
        }
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        undecided = settings.authorizationStatus == .notDetermined
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Asks the first time; after a refusal only System Settings can turn notifications on.
    func requestAuthorization() async {
        await refreshAuthorization()
        if undecided {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        } else if authorized == false {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
    }

    func post(_ kind: Kind, title: String, body: String, meetingID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind.category
        if kind == .detected || kind == .callEnded { content.sound = .default }
        if let meetingID { content.userInfo = ["meetingID": meetingID] }
        // One identifier per kind replaces an older banner instead of stacking them.
        let identifier = kind == .processed || kind == .stopped ? "\(kind.rawValue).\(meetingID ?? UUID().uuidString)" : kind.rawValue
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func clear(_ kind: Kind) {
        center.removeDeliveredNotifications(withIdentifiers: [kind.rawValue])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        let meetingID = response.notification.request.content.userInfo["meetingID"] as? String
        await MainActor.run { self.handle(category: category, action: action, meetingID: meetingID) }
    }

    private func handle(category: String, action: String, meetingID: String?) {
        guard let model, action != UNNotificationDismissActionIdentifier else { return }
        let clicked = action == UNNotificationDefaultActionIdentifier
        switch category {
        case Kind.detected.category where clicked || action == "start":
            model.startMeeting()
        case Kind.callEnded.category where action == "keep":
            model.keepRecording()
        case Kind.callEnded.category, Kind.quiet.category:
            model.stopMeeting()
        default:
            model.showMain(route: meetingID.map { .local($0) })
        }
    }
}
