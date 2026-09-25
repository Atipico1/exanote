import Foundation

/// A serial queue keeps PCM chunks in recording order. Network and model work
/// never run on Core Audio's callback queue; the CAF file remains the fallback.
final class LiveAudioSender: @unchecked Sendable {
    private let meetingID: String
    private let token: String
    private let queue = DispatchQueue(label: "exanote.live-upload", qos: .utility)
    private let onError: @Sendable (String) -> Void
    private var failed = false
    private var nextSequence = 0
    private var ready = false
    private var buffered: [Data] = []

    init(meetingID: String, token: String, onError: @escaping @Sendable (String) -> Void) {
        self.meetingID = meetingID
        self.token = token
        self.onError = onError
    }

    func append(_ pcm: Data) {
        queue.async {
            if self.ready { self.send(pcm) }
            else { self.buffered.append(pcm) }
        }
    }

    func activate() {
        queue.async {
            self.ready = true
            for pcm in self.buffered { self.send(pcm) }
            self.buffered.removeAll()
        }
    }

    private func send(_ pcm: Data) {
        guard !failed else { return }
        let operation = "chunk?sample_rate=48000&sequence=\(nextSequence)"
        var delivered = false
        for attempt in 0..<3 {
            if request(operation, body: pcm) {
                delivered = true
                break
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard delivered else {
            fail("실시간 기록이 중단됐어요. 전체 녹음은 계속 저장되고 있어요.")
            return
        }
        nextSequence += 1
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                _ = self.request("finish", body: Data())
                continuation.resume()
            }
        }
    }

    @discardableResult
    private func request(_ operation: String, body: Data) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/api/live/\(meetingID)/\(operation)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(token, forHTTPHeaderField: "X-Exanote-Token")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let semaphore = DispatchSemaphore(value: 0)
        var okay = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            okay = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return okay
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        onError(message)
    }
}
