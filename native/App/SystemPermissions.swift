import AppKit
import AVFoundation

/// Microphone and "System Audio Recording Only" access, checked without prompting and requested
/// on demand, for onboarding, Settings ▸ 권한 and the setup checklist.
@MainActor
final class SystemPermissions: ObservableObject {
    enum Status {
        case granted
        case notAsked
        case denied
        /// This macOS does not let the app read the state; macOS asks on the first recording.
        case unknown
    }

    @Published private(set) var microphone: Status = SystemPermissions.microphoneStatus()
    @Published private(set) var systemAudio: Status = SystemAudioAccess.status()

    /// Everything a recording needs, as far as the app can tell.
    var recordingReady: Bool {
        microphone == .granted && (systemAudio == .granted || systemAudio == .unknown)
    }

    func refresh() {
        let mic = Self.microphoneStatus()
        let audio = SystemAudioAccess.status()
        if mic != microphone { microphone = mic }
        if audio != systemAudio { systemAudio = audio }
    }

    /// Rechecks every second while a screen that shows these is open; the user may be flipping
    /// them in System Settings.
    func watch() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .authorized: break
        default: Self.open("Privacy_Microphone")
        }
        refresh()
    }

    func requestSystemAudio() async {
        switch SystemAudioAccess.status() {
        case .notAsked: _ = await SystemAudioAccess.request()
        case .denied, .unknown: Self.open("Privacy_ScreenCapture")
        case .granted: break
        }
        refresh()
    }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }
}

/// macOS has no public API for the system audio (process tap) permission. Like Apple's AudioCap
/// sample, this reads and requests it through TCC's functions, loaded at run time; when they are
/// missing the state is .unknown and macOS asks the first time a recording starts.
private enum SystemAudioAccess {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    nonisolated(unsafe) private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework, let pointer = dlsym(framework, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static func status() -> SystemPermissions.Status {
        guard let preflight = symbol("TCCAccessPreflight", as: Preflight.self) else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notAsked
        }
    }

    static func request() async -> Bool {
        guard let request = symbol("TCCAccessRequest", as: Request.self) else { return false }
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
