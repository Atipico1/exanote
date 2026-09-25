import AppKit
import Foundation

private let baseURL = URL(string: "http://127.0.0.1:8765")!

struct Utterance: Decodable {
    let start: Double
    let end: Double
    let speaker: Int?
    let text: String

    var timestamp: String {
        let seconds = Int(start)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var speakerLabel: String { speaker.map { "화자 \($0 + 1)" } ?? "미확인" }
}

struct MeetingResult: Decodable {
    let notes: String
    let transcript: String
    let utterances: [Utterance]
}

struct LiveRow: Decodable, Identifiable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
    let translation: String?
    let draft_translation: String?
    let translation_error: String?
    let overlap: Bool?

    var id: String { "\(start)-\(speaker)" }
    var timestamp: String {
        let seconds = Int(start)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct LivePreview: Decodable {
    let speaker: String
    let text: String
    let translation: String?
    let translation_error: String?
    let overlap: Bool?
}

struct LiveSnapshot: Decodable {
    let meeting_id: String
    let status: String
    let duration: Double
    let rows: [LiveRow]
    let preview: LivePreview?
    let translation_ready: Bool
    let translation_error: String?
    let error: String?
}

/// A moment the user marked while recording, in seconds of recorded audio.
struct Bookmark: Decodable, Hashable {
    let time: Double
    let note: String
}

/// Where the worker is with a meeting (server.py _with_progress).
struct ProcessingProgress: Decodable, Equatable {
    struct Download: Decodable, Equatable {
        let name: String
        let bytes: Int
        let expected_bytes: Int
    }

    let stage: String
    let fraction: Double
    let elapsed: Double
    let download: Download?

    var stageName: String {
        switch stage {
        case "decode": "오디오 준비"
        case "diarize": "말한 사람 구분"
        case "transcribe": "받아쓰기"
        case "align": "단어 시간 맞추기"
        case "summarize": "요약 작성"
        default: "처리"
        }
    }

    /// Seconds left, once enough of the job has run to extrapolate.
    var remaining: Double? {
        guard download == nil, fraction >= 0.05, elapsed >= 10 else { return nil }
        return elapsed / fraction * (1 - fraction)
    }
}

struct Meeting: Decodable, Identifiable {
    let id: String
    let title: String
    let created_at: String
    let status: String
    let filename: String
    let duration: Double?
    let language: String?
    let speakers: Int?
    let speaker_names: [String: String]?
    let error: String?
    let result: MeetingResult?
    let live: LiveSnapshot?
    let memo: String?
    let bookmarks: [Bookmark]?
    let progress: ProcessingProgress?
    let queue_position: Int?
    let recovered: Bool?
    let demo: Bool?

    var createdAt: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: created_at) ?? Date()
    }

    func openAudio() {
        NSWorkspace.shared.open(AppPaths.data.appending(path: id).appending(path: filename))
    }
}

private struct WorkerStatus: Decodable {
    struct ActiveRecording: Decodable { let id: String }
    let recording: ActiveRecording?
    let protocol_version: Int?
}

private struct Recovery: Decodable { let recovered: Meeting? }

private struct APIError: Decodable { let detail: String? }

@MainActor
final class MeetingStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: String?
    @Published var selected: Meeting?
    @Published var recording = false
    /// The meeting being recorded by this app right now.
    @Published private(set) var recordingID: String?
    @Published private(set) var recordingMode: RecordingMode?
    @Published var busy = false
    @Published var error: String?
    @Published private(set) var live: LiveSnapshot?
    @Published private(set) var liveError: String?
    /// A recording the previous run never finished, now queued from what reached the disk.
    @Published private(set) var recovered: Meeting?

    private var worker: Process?
    private var started = false
    @Published private(set) var stoppingForUpdate = false
    private var pendingMemos: [String: String] = [:]
    private var memoWrites = 0
    let capture = AudioCapture()
    private var liveSender: LiveAudioSender?
    private var livePoll: Task<Void, Never>?

    private var tokenPath: URL {
        AppPaths.data.appending(path: "ipc-token")
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            if let status = try? await fetchStatus() {
                if status.protocol_version != 3 {
                    try await replaceOutdatedWorker()
                }
            } else {
                try launchWorker()
            }
            var ready = false
            for _ in 0..<30 {
                if (try? await fetchStatus()) != nil { ready = true; break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard ready else { throw WorkerFailure("로컬 분석 작업을 시작하지 못했습니다. Python 환경을 확인하세요.") }
            // The worker outlives the app. If it still has a recording open, the app that was
            // capturing it quit or crashed: process what reached the disk.
            if let state = try? await fetchStatus(), state.recording != nil, !capture.isRunning,
               let recovery: Recovery = try? await fetch("api/record/recover", method: "POST") {
                recovered = recovery.recovered
            }
            try await refresh()
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    try? await refresh()
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// The Python worker survives the app, so an app update can otherwise keep talking to an
    /// older API indefinitely. Only stop the authenticated Exanote worker listening on our port.
    private func replaceOutdatedWorker() async throws {
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        listener.arguments = ["-nP", "-tiTCP:8765", "-sTCP:LISTEN"]
        let output = Pipe()
        listener.standardOutput = output
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        let ids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        listener.waitUntilExit()
        guard listener.terminationStatus == 0, ids.count == 1, let pid = Int32(ids[0]) else {
            throw WorkerFailure("이전 버전의 로컬 작업 프로세스를 확인하지 못했습니다. Exanote를 다시 실행하세요.")
        }

        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/ps")
        command.arguments = ["-p", String(pid), "-o", "command="]
        let commandOutput = Pipe()
        command.standardOutput = commandOutput
        command.standardError = FileHandle.nullDevice
        try command.run()
        let line = String(decoding: commandOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        command.waitUntilExit()
        guard command.terminationStatus == 0,
              line.contains("-m exanote.cli serve --port 8765"),
              (line.contains("/Exanote.app/") || line.contains("/.venv/bin/python")) else {
            throw WorkerFailure("다른 프로그램이 로컬 작업 포트를 사용 중입니다.")
        }
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            throw WorkerFailure("이전 버전의 로컬 작업 프로세스를 종료하지 못했습니다.")
        }
        var stopped = false
        for _ in 0..<30 {
            if (try? await fetchStatus()) == nil { stopped = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard stopped else { throw WorkerFailure("이전 버전의 로컬 작업 프로세스가 종료되지 않았습니다.") }
        try launchWorker()
    }

    private func launchWorker() throws {
        let environment = ProcessInfo.processInfo.environment
        let process = Process()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A distributed app carries its own Python in Resources/python (see scripts/build_app.sh).
        if environment["EXANOTE_ROOT"] == nil,
           let bundled = Bundle.main.resourceURL?.appending(path: "python/bin/python3"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            var workerEnvironment = environment
            workerEnvironment["PYTHONDONTWRITEBYTECODE"] = "1"  // Never write into the signed app bundle.
            workerEnvironment["PYTHONNOUSERSITE"] = "1"
            workerEnvironment.removeValue(forKey: "PYTHONPATH")
            workerEnvironment.removeValue(forKey: "PYTHONHOME")
            process.executableURL = bundled
            process.arguments = ["-P", "-m", "exanote.cli", "serve", "--port", "8765"]
            process.environment = workerEnvironment
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            try process.run()
            worker = process
            return
        }
        let root: URL
        if let rootPath = environment["EXANOTE_ROOT"] {
            root = URL(fileURLWithPath: rootPath)
        } else {
            var candidate = Bundle.main.bundleURL
            var found: URL?
            for _ in 0..<12 {
                if FileManager.default.fileExists(atPath: candidate.appending(path: "pyproject.toml").path) {
                    found = candidate
                    break
                }
                candidate.deleteLastPathComponent()
            }
            guard let found else { throw WorkerFailure("저장소 경로를 찾지 못했습니다. EXANOTE_ROOT 환경 변수를 설정하세요.") }
            root = found
        }
        let python = root.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw WorkerFailure("Python 환경이 없습니다. 저장소에서 `uv pip install --python .venv/bin/python -e .`을 실행하세요.")
        }
        process.executableURL = python
        process.arguments = ["-m", "exanote.cli", "serve", "--port", "8765"]
        process.currentDirectoryURL = root
        try process.run()
        worker = process
    }

    private func fetch<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: query.isEmpty ? baseURL.appending(path: path) : baseURL.appending(path: path).appending(queryItems: query))
        request.httpMethod = method
        request.httpBody = body
        if let token = try? String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            request.setValue(token, forHTTPHeaderField: "X-Exanote-Token")
        }
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw WorkerFailure("로컬 작업 프로세스에 연결하지 못했습니다.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = try? JSONDecoder().decode(APIError.self, from: data)
            throw WorkerFailure(detail?.detail ?? "로컬 작업 오류 (\(response.statusCode))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchStatus() async throws -> WorkerStatus { try await fetch("api/status") }

    /// The authenticated worker refuses shutdown while recording, queued or processing.
    /// Do not replace Python files until that process has actually exited.
    func stopWorkerForUpdate() async -> Bool {
        guard !recording, !capture.isRunning, !busy, memoWrites == 0 else { return false }
        for (id, text) in pendingMemos { await saveMemo(meetingID: id, text: text) }
        guard pendingMemos.isEmpty, memoWrites == 0 else { return false }
        stoppingForUpdate = true
        busy = true
        defer { busy = false }
        do {
            struct Reply: Decodable { let ok: Bool }
            let _: Reply = try await fetch("api/shutdown", method: "POST")
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                do { _ = try await fetchStatus() }
                catch let error as URLError where error.code == .cannotConnectToHost {
                    return true
                }
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return true
        } catch { /* Fail closed: a busy or unavailable worker must not be interrupted. */ }
        stoppingForUpdate = false
        return false
    }

    func refresh() async throws {
        _ = try await fetchStatus()
        // This app's capture is the truth: the worker may have restarted mid-recording.
        recording = capture.isRunning
        meetings = try await fetch("api/meetings")
        if selectedID == nil { selectedID = meetings.first?.id }
        await loadSelected()
    }

    func loadSelected() async {
        guard let selectedID else { selected = nil; return }
        do { selected = try await fetch("api/meetings/\(selectedID)") }
        catch { self.error = error.localizedDescription }
    }

    func renameSpeaker(meetingID: String, speaker: Int, name: String) async {
        struct Change: Encodable { let speaker: Int; let name: String }
        do {
            let _: Meeting = try await fetch("api/meetings/\(meetingID)/speakers", method: "POST",
                                             body: JSONEncoder().encode(Change(speaker: speaker, name: name)),
                                             contentType: "application/json")
            error = nil
            await loadSelected()
        } catch { self.error = error.localizedDescription }
    }

    /// event: the calendar event happening now; it names the meeting and can file it into a folder.
    func startRecording(title: String? = nil, event: UpcomingMeeting? = nil) async {
        guard !recording, !stoppingForUpdate else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            struct Start: Encodable { let title: String?; let event_id: String?; let series_id: String?; let live_translation: Bool }
            let body = try JSONEncoder().encode(Start(title: title ?? event?.title, event_id: event?.eventID,
                                                      series_id: event?.seriesID, live_translation: false))
            let item: Meeting = try await fetch("api/record/start", method: "POST", body: body, contentType: "application/json")
            do {
                let audioURL = tokenPath.deletingLastPathComponent().appending(path: item.id).appending(path: item.filename)
                try await capture.start(at: audioURL)
            } catch {
                let _: Meeting? = try? await fetch("api/record/cancel", method: "POST")
                throw error
            }
            liveSender = nil
            live = nil
            liveError = nil
            recordingID = item.id
            recordingMode = .afterRecording
            recording = true
            selectedID = item.id
            livePoll?.cancel()
            try await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func enableLiveTranslation() async {
        guard recording, let id = recordingID, recordingMode == .afterRecording, !busy else { return }
        busy = true
        liveError = nil
        defer { busy = false }
        do {
            let _: LiveSnapshot = try await fetch("api/live/\(id)/start", method: "POST")
            let sender = LiveAudioSender(meetingID: id,
                                         token: try String(contentsOf: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) { [weak self] message in
                Task { @MainActor in self?.liveError = message }
            }
            let offset = capture.setLiveChunkHandler { [sender] pcm in sender.append(pcm) }
            let snapshot: LiveSnapshot
            do {
                snapshot = try await fetch("api/live/\(id)/offset", method: "POST",
                                           query: [URLQueryItem(name: "seconds", value: String(offset))])
            } catch {
                capture.clearLiveChunkHandler()
                throw error
            }
            sender.activate()
            liveSender = sender
            live = snapshot
            recordingMode = .liveTranslation
            livePoll?.cancel()
            livePoll = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled && self.recordingID == id {
                    if let snapshot: LiveSnapshot = try? await self.fetch("api/live/\(id)") { self.live = snapshot }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        } catch { liveError = error.localizedDescription }
    }

    func stopRecording() async {
        guard recording, let id = recordingID else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await capture.stop()
            await liveSender?.finish()
        } catch {
            let _: Meeting? = try? await fetch("api/record/cancel", method: "POST")
            recording = false
            recordingID = nil
            recordingMode = nil
            livePoll?.cancel()
            liveSender = nil
            self.error = error.localizedDescription
            return
        }
        recording = false
        recordingID = nil
        recordingMode = nil
        livePoll?.cancel()
        let hadLiveSender = liveSender != nil
        liveSender = nil
        if hadLiveSender {
            if let snapshot: LiveSnapshot = try? await fetch("api/live/\(id)") { live = snapshot }
            livePoll = Task { [weak self] in
                guard let self else { return }
                for _ in 0..<90 where !Task.isCancelled {
                    guard self.live?.meeting_id == id,
                          self.live?.rows.contains(where: { $0.translation == nil && $0.translation_error == nil }) == true else { break }
                    try? await Task.sleep(for: .seconds(1))
                    if let snapshot: LiveSnapshot = try? await self.fetch("api/live/\(id)") {
                        self.live = snapshot
                    }
                }
            }
        }
        do {
            // With the meeting id the worker finishes it even if it restarted during the meeting.
            let item: Meeting = try await fetch("api/record/stop", method: "POST", query: [URLQueryItem(name: "meeting_id", value: id)])
            selectedID = item.id
            try await refresh()
        } catch {
            // The audio is on disk; a restarted worker queues it by itself (server._resume_interrupted).
            self.error = error.localizedDescription
        }
    }

    func pauseRecording() {
        capture.pause()
        objectWillChange.send()
    }

    func resumeRecording() {
        do {
            try capture.resume()
            objectWillChange.send()
        } catch { self.error = error.localizedDescription }
    }

    func addBookmark(meetingID: String, time: Double, note: String = "") async {
        struct Change: Encodable { let time: Double; let note: String }
        do {
            let _: Meeting = try await fetch("api/meetings/\(meetingID)/bookmarks", method: "POST",
                                             body: JSONEncoder().encode(Change(time: time, note: note)), contentType: "application/json")
            if selectedID == meetingID { await loadSelected() }
        } catch { self.error = error.localizedDescription }
    }

    func deleteBookmark(meetingID: String, index: Int) async {
        do {
            let _: Meeting = try await fetch("api/meetings/\(meetingID)/bookmarks/\(index)", method: "DELETE")
            if selectedID == meetingID { await loadSelected() }
        } catch { self.error = error.localizedDescription }
    }

    /// Saves the memo without reloading, so the editor keeps its cursor.
    func stageMemo(meetingID: String, text: String) {
        pendingMemos[meetingID] = text
    }

    func saveMemo(meetingID: String, text: String) async {
        guard !stoppingForUpdate else { return }
        memoWrites += 1
        defer { memoWrites -= 1 }
        struct Change: Encodable { let text: String }
        do {
            let _: Meeting = try await fetch("api/meetings/\(meetingID)/memo", method: "PUT",
                                             body: JSONEncoder().encode(Change(text: text)), contentType: "application/json")
            if pendingMemos[meetingID] == text { pendingMemos.removeValue(forKey: meetingID) }
        } catch { self.error = error.localizedDescription }
    }

    func dismissRecovered() { recovered = nil }

    func importFile(_ url: URL) async {
        guard !stoppingForUpdate else { return }
        busy = true
        error = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            let boundary = UUID().uuidString
            var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent.replacingOccurrences(of: "\"", with: ""))\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            body.append(try Data(contentsOf: url))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let item: Meeting = try await fetch("api/import", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
            selectedID = item.id
            try await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

private struct WorkerFailure: LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
