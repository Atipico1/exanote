import AppKit
import AVFoundation
import SwiftUI

/// Recording asks for the microphone here. The other participants' audio uses
/// "System Audio Recording Only", which macOS asks for itself the first time a recording starts.
enum RecordingPermission: String, Identifiable {
    case microphone

    var id: String { rawValue }

    var title: String { "마이크 접근을 허용해 주세요" }
    var message: String { "내 목소리를 녹음하려면 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Exanote를 켜 주세요." }
    private var settingsURL: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")! }

    func openSettings() { NSWorkspace.shared.open(settingsURL) }

    /// Asks once if undecided. After a refusal macOS only allows turning it on in System Settings.
    static func firstMissing() async -> RecordingPermission? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? nil : .microphone
        default: return .microphone
        }
    }
}

struct PermissionAlert: ViewModifier {
    @Binding var permission: RecordingPermission?

    func body(content: Content) -> some View {
        content.alert(permission?.title ?? "", isPresented: Binding(get: { permission != nil }, set: { if !$0 { permission = nil } }), presenting: permission) { item in
            Button("시스템 설정 열기") { item.openSettings() }.keyboardShortcut(.defaultAction)
            Button("취소", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}
