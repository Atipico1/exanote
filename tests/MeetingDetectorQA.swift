import Foundation

@main
struct MeetingDetectorQA {
    static func main() {
        let cases: [(String, String?)] = [
            ("us.zoom.xos", "Zoom"),
            ("zoom.us.ZoomAudioDevice", "Zoom"),
            ("com.microsoft.teams2", "Microsoft Teams"),
            ("com.microsoft.teams.helper", "Microsoft Teams"),
            ("com.tinyspeck.slackmacgap.helper", "Slack"),
            ("com.hnc.Discord.helper", "Discord"),
            ("com.google.Chrome.helper", "Chrome"),
            ("com.apple.Safari", "Safari"),
            ("com.apple.WebKit.WebContent", "Safari"),
            ("com.google.Chromebook", nil),
            ("org.example.microphone", nil),
        ]
        for (bundleID, expected) in cases {
            let actual = MeetingDetector.classify(bundleID: bundleID)?.name
            precondition(actual == expected, "\(bundleID): \(actual ?? "nil") != \(expected ?? "nil")")
        }
        print("meeting bundle classification: \(cases.count) passed")
        if let active = MeetingDetector.detect() {
            print("current microphone process: \(active.name)")
        } else {
            print("current microphone process: none of the supported apps")
        }
    }
}
