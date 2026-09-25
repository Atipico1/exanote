import EventKit
import Foundation

/// Upcoming meetings read through macOS Calendar (EventKit).
///
/// This covers every account the user already added to Calendar — Google,
/// iCloud, Exchange — without a Google OAuth client or app verification.
/// Requires NSCalendarsFullAccessUsageDescription in Info.plist.
struct UpcomingMeeting: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    let joinURL: URL?
    let eventID: String?
    /// Shared by every occurrence of a recurring event; nil for a one-off event.
    let seriesID: String?
}

@MainActor
final class UpcomingMeetingsStore: ObservableObject {
    @Published private(set) var meetings: [UpcomingMeeting] = []
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var connecting = false
    @Published private(set) var error: String?

    private var store = EKEventStore()
    private var observer: NSObjectProtocol?

    init() {
        // Register even when permission is initially denied; granting access in Settings
        // must not depend on a previous successful connect() call.
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func refreshAuthorization() {
        store = EKEventStore()
        reload()
    }

    /// Shows the macOS permission prompt only the first time.
    func connect() async {
        guard !connecting else { return }
        connecting = true
        error = nil
        defer { connecting = false }
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .notDetermined {
            do { _ = try await store.requestFullAccessToEvents() }
            catch {
                self.error = "캘린더 접근을 요청하지 못했어요. 시스템 설정에서 Exanote의 캘린더 접근을 확인해 주세요."
            }
            access = EKEventStore.authorizationStatus(for: .event)
            if access == .notDetermined, error == nil {
                error = "캘린더 권한 응답을 받지 못했어요. 시스템 설정에서 캘린더 접근을 확인해 주세요."
            }
        }
        guard access == .fullAccess else { meetings = []; return }
        reload()
    }

    func reload(hours: Double = 24) {
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess else { meetings = []; return }
        error = nil
        let now = Date()
        // Include meetings that started up to 15 minutes ago so a late join still shows.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        meetings = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { UpcomingMeeting(id: $0.calendarItemIdentifier + "\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "제목 없음", start: $0.startDate, end: $0.endDate, calendar: $0.calendar.title, joinURL: Self.joinURL($0),
                                   eventID: $0.eventIdentifier, seriesID: $0.hasRecurrenceRules ? ($0.calendarItemExternalIdentifier ?? $0.calendarItemIdentifier) : nil) }
    }

    /// The event the user is most likely in right now: started up to 10 minutes early or late and
    /// not over. Names a recording started without a title.
    func happeningNow() -> UpcomingMeeting? {
        guard access == .fullAccess else { return nil }
        reload()
        let now = Date()
        return meetings
            .filter { $0.start.addingTimeInterval(-10 * 60) <= now && now < $0.end }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    private nonisolated static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private nonisolated static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]

    /// Calendar invitations put the call link in the URL, location or notes depending on the provider.
    nonisolated static func joinURL(_ event: EKEvent) -> URL? {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        let range = NSRange(text.startIndex..., in: text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        return links.first { url in
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}
