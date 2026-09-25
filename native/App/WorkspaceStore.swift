import AppKit
import Foundation

struct WorkspaceOption: Decodable, Hashable, Identifiable {
    let kind: String
    let name: String
    let path: String
    let account: String
    /// Set for kind "team": a folder with exanote-team.json that the owner's Exanote created.
    var team_id: String? = nil
    var folder_id: String? = nil
    var owner: String? = nil

    var id: String { path }

    var symbol: String {
        switch kind {
        case "icloud": "icloud"
        case "team": "person.3"
        case "google-shared": "person.2"
        case "google": "externaldrive.badge.person.crop"
        default: "laptopcomputer"
        }
    }

    var purpose: String {
        switch kind {
        case "icloud": "내 다른 Mac과 동기화"
        case "team": "팀과 공유 · Exanote 팀"
        case "google-shared": "팀과 공유 · Google 공유 드라이브"
        case "google": "내 Google Drive"
        default: "이 Mac에만 보관"
        }
    }

    var sectionTitle: String { kind == "icloud" ? "다른 Mac" : name }
}

struct SyncStatus: Decodable {
    let last_sync: String?
    let error: String?
    let exported_ids: [String]
}

struct WorkspaceOverview: Decodable {
    let options: [WorkspaceOption]
    let selected: WorkspaceOption?
    let status: SyncStatus
}

struct SharedMeeting: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let created_at: String
    let duration: Double?
    let speakers: Int?
    let language: String?
    let author: String
    let mine: Bool?
    let transcript: String?
    let summary: String?
    let folder: String?

    var createdAt: Date { parseISODate(created_at) ?? Date() }
    var stillSyncing: Bool { transcript == nil || summary == nil }
}

/// Talks to the loopback worker with the same per-user token as MeetingStore.
enum LocalAPI {
    static let base = URL(string: "http://127.0.0.1:8765")!

    static var dataDirectory: URL { AppPaths.data }

    static func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, query: [URLQueryItem] = []) async throws -> T {
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token = try? String(contentsOf: dataDirectory.appending(path: "ipc-token"), encoding: .utf8) {
            request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Exanote-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAPIError(message: (try? JSONDecoder().decode(ErrorDetail.self, from: data))?.detail ?? "로컬 작업 프로세스에 연결하지 못했습니다.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct ErrorDetail: Decodable { let detail: String? }

struct LocalAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var overview: WorkspaceOverview?
    @Published private(set) var shared: [SharedMeeting] = []
    /// Local meetings from the fast endpoint, so lists appear at launch before MeetingStore's first poll.
    @Published private(set) var localMeetings: [Meeting] = []
    @Published var error: String?

    private var started = false

    var selected: WorkspaceOption? { overview?.selected }
    var googleDriveInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Google Drive.app") }
    var googleSignedIn: Bool { overview?.options.contains { $0.kind.hasPrefix("google") } ?? false }

    func start() async {
        guard !started else { return }
        started = true
        await Self.requestCloudStorageAccess()
        while !Task.isCancelled {
            await refresh()
            // Cloud folders are polled; File Provider does not reliably report remote changes.
            try? await Task.sleep(for: .seconds(overview == nil ? 2 : 10))
        }
    }

    /// macOS asks once per app before it lets anything list a File Provider folder such as
    /// ~/Library/CloudStorage/GoogleDrive-*. The prompt only appears for the app itself: the Python
    /// worker it launches just blocks in opendir for about ten seconds and gets nothing. Listing each
    /// folder here first shows "Exanote would like to access files in Google Drive" at launch.
    private static func requestCloudStorageAccess() async {
        await Task.detached(priority: .utility) {
            let files = FileManager.default
            let root = files.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
            for folder in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                _ = try? files.contentsOfDirectory(atPath: folder.path)
            }
        }.value
    }

    func refresh() async {
        if let local: [Meeting] = try? await LocalAPI.request("api/meetings") { localMeetings = local }
        guard let overview: WorkspaceOverview = try? await LocalAPI.request("api/workspaces") else { return }
        self.overview = overview
        shared = overview.selected == nil ? [] : ((try? await LocalAPI.request("api/shared")) ?? shared)
    }

    /// A user-selected File Provider folder grants Exanote access when macOS
    /// does not show a permission prompt for background directory reads.
    func connectGoogleDriveFolder() async {
        let panel = NSOpenPanel()
        panel.title = "Google Drive 연결"
        panel.message = "Google Drive 계정 폴더를 선택해 주세요."
        panel.prompt = "연결"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathComponents.contains(where: { $0.hasPrefix("GoogleDrive-") }) else {
            error = "Google Drive 폴더를 선택해 주세요."
            return
        }
        error = nil
        await refresh()
    }

    func choose(_ path: String?) async {
        struct Choice: Encodable { let path: String? }
        do {
            overview = try await LocalAPI.request("api/workspace", method: "PUT", body: JSONEncoder().encode(Choice(path: path)))
            error = nil
            shared = []
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func meeting(_ id: String) async throws -> SharedMeeting {
        try await LocalAPI.request("api/shared/\(id)")
    }

    /// Drops a deleted meeting from every list right away instead of waiting for the next poll.
    func forget(meetingID: String) {
        localMeetings.removeAll { $0.id == meetingID }
        shared.removeAll { $0.id == meetingID }
    }

    func rename(meetingID: String, title: String) async {
        struct Change: Encodable { let title: String }
        struct Ignored: Decodable {}
        _ = try? await LocalAPI.request("api/meetings/\(meetingID)/title", method: "POST", body: JSONEncoder().encode(Change(title: title))) as Ignored
    }

    /// Re-runs transcription, diarization and notes for a local meeting (server.py's retry endpoint).
    func retry(meetingID: String) async {
        struct Ignored: Decodable {}
        do {
            _ = try await LocalAPI.request("api/meetings/\(meetingID)/retry", method: "POST") as Ignored
        } catch { self.error = error.localizedDescription }
    }

    /// Sidebar/detail label for one local meeting, or nil when sync is off or it is not finished.
    func syncLabel(for meeting: Meeting) -> (text: String, symbol: String)? {
        guard let selected, meeting.status == "done" else { return nil }
        if overview?.status.exported_ids.contains(meeting.id) == true {
            return ("\(selected.name)에 저장됨", "checkmark.circle")
        }
        return ("\(selected.name)에 저장하는 중", "arrow.triangle.2.circlepath")
    }
}
