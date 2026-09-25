import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle replaces the app; meeting data and models live outside its bundle.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published var canCheck = false
    @Published var automaticChecks = false {
        didSet { if controller.updater.automaticallyChecksForUpdates != automaticChecks { controller.updater.automaticallyChecksForUpdates = automaticChecks } }
    }
    @Published var automaticDownloads = false {
        didSet { if controller.updater.automaticallyDownloadsUpdates != automaticDownloads { controller.updater.automaticallyDownloadsUpdates = automaticDownloads } }
    }
    @Published private(set) var waitingToInstall = false
    private var installOnQuit = false
    private var workerStopped = false
    private var preparation: Task<Void, Never>?
    private var completions: [() -> Void] = []
    private var observers: [NSKeyValueObservation] = []
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    func start() {
        guard observers.isEmpty else { return }
        let updater = controller.updater
        observers = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                MainActor.assumeIsolated { self?.canCheck = value.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] value, _ in
                MainActor.assumeIsolated { self?.automaticChecks = value.automaticallyChecksForUpdates }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] value, _ in
                MainActor.assumeIsolated { self?.automaticDownloads = value.automaticallyDownloadsUpdates }
            }
        ]
        controller.startUpdater()
    }

    func check() { controller.checkForUpdates(nil) }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let store = AppModel.shared.store
        guard !store.recording, !store.busy else {
            throw NSError(domain: "app.exanote.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "녹음이 끝난 뒤 업데이트를 확인해 주세요."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        prepareForInstallation(then: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installOnQuit = true
        return false
    }

    /// Sparkle can also install on an ordinary quit, bypassing its relaunch delegate.
    func deferTerminationForUpdate() -> Bool {
        guard installOnQuit || waitingToInstall, !workerStopped else { return false }
        prepareForInstallation { NSApp.reply(toApplicationShouldTerminate: true) }
        return true
    }

    private func prepareForInstallation(then completion: @escaping () -> Void) {
        completions.append(completion)
        guard preparation == nil else { return }
        waitingToInstall = true
        preparation = Task { @MainActor in
            let store = AppModel.shared.store
            while !Task.isCancelled {
                if await store.stopWorkerForUpdate() {
                    workerStopped = true
                    let callbacks = completions
                    completions.removeAll()
                    callbacks.forEach { $0() }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject private var updates = AppUpdater.shared
    var body: some View {
        SettingsSection("업데이트") {
            SettingsRow(symbol: "arrow.triangle.2.circlepath", title: "새 버전 확인",
                        detail: updates.waitingToInstall ? "녹음과 처리가 끝나면 업데이트를 설치하고 다시 열어요" : "회의 기록과 내려받은 모델은 그대로 유지돼요") {
                Button("업데이트 확인…") { updates.check() }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .disabled(!updates.canCheck)
            }
            SettingsToggle(symbol: "clock", title: "자동으로 업데이트 확인", detail: "새 버전이 있으면 알려줘요", isOn: $updates.automaticChecks)
            SettingsToggle(symbol: "arrow.down.circle", title: "자동으로 업데이트 다운로드", detail: "받아 둔 업데이트는 작업이 끝나고 앱을 종료할 때 설치해요", isOn: $updates.automaticDownloads)
                .disabled(!updates.automaticChecks)
        }
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject private var updates = AppUpdater.shared
    var body: some View {
        Button("업데이트 확인…") { updates.check() }.disabled(!updates.canCheck)
    }
}
