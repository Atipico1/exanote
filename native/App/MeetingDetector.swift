import CoreAudio
import Foundation

struct MeetingSignal: Equatable {
    let name: String
    let bundleID: String
}

/// Notices a call when a known meeting app or browser starts using the microphone.
/// Core Audio reports which processes are capturing input, so this needs no Automation,
/// Accessibility or Screen Recording permission and never reads tabs or window titles.
@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var active: MeetingSignal?

    private static let apps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("company.thebrowser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
    ]

    func start() async {
        while !Task.isCancelled {
            let signal = Self.detect()
            if signal != active { active = signal }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    nonisolated static func detect() -> MeetingSignal? {
        for process in HAL.objects(HAL.system, kAudioHardwarePropertyProcessObjectList) {
            guard HAL.value(process, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) == 1,
                  let bundleID = HAL.string(process, kAudioProcessPropertyBundleID),
                  let app = apps.first(where: { bundleID.hasPrefix($0.prefix) }) else { continue }
            return MeetingSignal(name: app.name, bundleID: bundleID)
        }
        return nil
    }
}
