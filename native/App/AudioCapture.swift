import AVFoundation
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case noAudio
    case device(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudio: "소리가 녹음되지 않았어요. 마이크와 시스템 오디오 녹음 권한을 확인하세요."
        case .device(let step, let status): "오디오 장치를 열지 못했어요. (\(step) \(status))"
        }
    }
}

/// What the recording controls show: recorded time and how loud each side is right now.
struct CaptureSnapshot {
    /// Seconds of audio in the file. Paused time is not counted, so it matches transcript times.
    var seconds: Double
    /// RMS since the previous snapshot, 0...1.
    var microphone: Float
    var system: Float
    /// Recorded seconds since either side was above room noise.
    var quietFor: Double
    /// Recorded seconds of exact digital silence on both sides, which means nothing reaches us at all
    /// (a denied System Audio permission or a muted device), unlike a quiet room.
    var deadFor: Double
    /// Seconds since the audio device last delivered a buffer, while not paused.
    var stalledFor: Double
}

/// Records the other participants through a Core Audio process tap on system output and your
/// voice from the default microphone. Both run inside one private aggregate device, so they share
/// a clock. They are kept apart in a two-channel file (0 = microphone, 1 = system audio) so the
/// worker can tell your words from the other participants'. Needs Microphone and "System Audio
/// Recording Only" permission; the screen is never captured.
///
/// The file is 16-bit PCM CAF: if the app crashes, everything up to the last buffer can still be
/// read (an unfinished AAC .m4a cannot be opened at all). The worker compresses it afterwards.
/// When the default microphone or output changes mid-meeting (AirPods connected, a USB headset
/// unplugged) or the device stops delivering audio, the device is rebuilt and the same file goes on.
/// Pausing closes the device, so macOS's microphone indicator goes off while paused.
@MainActor
final class AudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: CaptureWriter?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watchdog: Task<Void, Never>?
    private var pendingReopen: Task<Void, Never>?
    private var primer: Process?
    private var lastOpened = Date.distantPast
    private(set) var paused = false
    /// Set when the device could not be reopened after a change; recording resumes on the next change.
    private(set) var deviceProblem: String?

    var isRunning: Bool { writer != nil }

    func start(at url: URL, onChunk: (@Sendable (Data) -> Void)? = nil) async throws {
        let writer = try CaptureWriter(url: url, onChunk: onChunk)
        do {
            try openDevice(for: writer)
        } catch {
            closeDevice()
            writer.discard()
            throw error
        }
        self.writer = writer
        paused = false
        deviceProblem = nil
        listenForDeviceChanges()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkStalled()
            }
        }
    }

    func stop() async throws {
        guard let writer else { throw CaptureError.noAudio }
        stopListening()
        watchdog?.cancel()
        pendingReopen?.cancel()
        stopPrimer()
        closeDevice()
        self.writer = nil
        paused = false
        guard writer.finish() > 0 else { throw CaptureError.noAudio }
    }

    func setLiveChunkHandler(_ handler: @escaping @Sendable (Data) -> Void) -> Double {
        writer?.setChunkHandler(handler) ?? 0
    }

    func clearLiveChunkHandler() {
        _ = writer?.setChunkHandler(nil)
    }

    func pause() {
        guard writer != nil, !paused else { return }
        paused = true
        stopPrimer()
        closeDevice()
        writer?.flushPending()
    }

    func resume() throws {
        guard let writer, paused else { return }
        do { try openDevice(for: writer) }
        catch { closeDevice(); throw error }
        writer.markOpened()
        paused = false
    }

    func snapshot() -> CaptureSnapshot? {
        guard let writer else { return nil }
        var snapshot = writer.snapshot()
        if paused { snapshot.stalledFor = 0 }
        return snapshot
    }

    // MARK: Device

    private func openDevice(for writer: CaptureWriter) throws {
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: HAL.ownProcess().map { [$0] } ?? [])
        tap.uuid = UUID()
        tap.isPrivate = true
        tap.muteBehavior = .unmuted
        try check("tap", AudioHardwareCreateProcessTap(tap, &tapID))
        guard let output = HAL.defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice) else { throw CaptureError.device("output", 0) }
        var devices: [[String: Any]] = [[kAudioSubDeviceUIDKey: output]]
        if let input = HAL.defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice), input != output {
            devices.append([kAudioSubDeviceUIDKey: input, kAudioSubDeviceDriftCompensationKey: true])
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Exanote",
            kAudioAggregateDeviceUIDKey: "app.exanote.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: devices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check("device", AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))
        let rate = HAL.value(deviceID, kAudioDevicePropertyNominalSampleRate, default: Float64(0)).flatMap { $0 > 0 ? $0 : nil } ?? CaptureWriter.rate
        try check("io", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, writer.queue) { _, input, _, _, _ in
            writer.consume(input, rate: rate)
        })
        try check("start", AudioDeviceStart(deviceID, procID))
        lastOpened = Date()
        try primeOutput()
    }

    /// On some Macs the system-output tap does not deliver its first buffer until another process
    /// plays to the output device. Our own process is excluded from the tap, so use macOS afplay
    /// for a short silent file to wake the device without recording or making audible sound.
    private func primeOutput() throws {
        stopPrimer()
        let url = FileManager.default.temporaryDirectory.appending(path: "exanote-output-prime.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)!
            for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 12_000) }
            buffer.frameLength = 12_000
            try file.write(from: buffer)
            file.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        primer = process
    }

    private func stopPrimer() {
        if primer?.isRunning == true { primer?.terminate() }
        primer = nil
    }

    private func closeDevice() {
        if deviceID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(deviceID, procID)
                AudioDeviceDestroyIOProcID(deviceID, procID)
            }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Rebuilds the device on the current defaults, keeping the same file.
    private func reopen() {
        guard let writer, !paused else { return }
        closeDevice()
        do {
            try openDevice(for: writer)
            deviceProblem = nil
        } catch {
            closeDevice()
            lastOpened = Date()
            deviceProblem = error.localizedDescription
        }
    }

    private func scheduleReopen() {
        // A device switch arrives as several notifications; act once they settle.
        pendingReopen?.cancel()
        pendingReopen = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.reopen()
        }
    }

    private func checkStalled() {
        guard let snapshot = snapshot(), !paused else { return }
        // Also covers sleep/wake and a device that vanished without a default-device change.
        if snapshot.stalledFor > 3, Date().timeIntervalSince(lastOpened) > 5 { reopen() }
    }

    private func listenForDeviceChanges() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = HAL.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.scheduleReopen() }
            }
            if AudioObjectAddPropertyListenerBlock(HAL.system, &address, DispatchQueue.main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func stopListening() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(HAL.system, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw CaptureError.device(step, status) }
    }
}

/// Writes the aggregate device's input as two-channel 48 kHz PCM: channel 0 mixes the microphone
/// streams, channel 1 the system-audio tap. An aggregate device lists its sub-devices' streams first
/// and its taps last, and the global tap is stereo, so the last two channels are the system audio.
/// A device at another rate (a Bluetooth headset at 24 kHz) is resampled so one file holds all.
private final class CaptureWriter: @unchecked Sendable {
    static let rate: Double = 48_000
    private static let tapChannels = 2
    private static let audibleRMS: Float = 0.003  // about -50 dBFS, above a quiet room

    let queue = DispatchQueue(label: "exanote.capture", qos: .userInitiated)
    private let url: URL
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private var onChunk: (@Sendable (Data) -> Void)?
    private var pendingPCM = Data()
    private var inputFormats: [Double: AVAudioFormat] = [:]
    private var converters: [Double: AVAudioConverter] = [:]

    private let lock = NSLock()
    private var frames: AVAudioFramePosition = 0
    private var microphoneLevel: Float = 0
    private var systemLevel: Float = 0
    private var lastAudibleFrame: AVAudioFramePosition = 0
    private var lastSignalFrame: AVAudioFramePosition = 0
    private var lastBuffer = Date()

    init(url: URL, onChunk: (@Sendable (Data) -> Void)?) throws {
        self.url = url
        self.onChunk = onChunk
        try? FileManager.default.removeItem(at: url)
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func markOpened() {
        lock.withLock { lastBuffer = Date() }
    }

    func consume(_ input: UnsafePointer<AudioBufferList>, rate: Double) {
        lock.withLock { lastBuffer = Date() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let count = buffers.map { $0.mNumberChannels > 0 ? Int($0.mDataByteSize) / (4 * Int($0.mNumberChannels)) : 0 }.max() ?? 0
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat(rate), frameCapacity: AVAudioFrameCount(count)),
              let channelData = pcm.floatChannelData else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        let microphone = channelData[0], system = channelData[1]
        microphone.initialize(repeating: 0, count: count)
        system.initialize(repeating: 0, count: count)
        var tapRemaining = Self.tapChannels
        for buffer in buffers.reversed() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let isTap = tapRemaining > 0
            tapRemaining -= channels
            let out = isTap ? system : microphone
            let gain = 1 / Float(channels)
            for frame in 0..<min(count, Int(buffer.mDataByteSize) / (4 * channels)) {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                out[frame] += sum * gain
            }
        }
        var micEnergy: Float = 0, systemEnergy: Float = 0, signal = false
        for frame in 0..<count {
            microphone[frame] = min(1, max(-1, microphone[frame]))
            system[frame] = min(1, max(-1, system[frame]))
            micEnergy += microphone[frame] * microphone[frame]
            systemEnergy += system[frame] * system[frame]
            if microphone[frame] != 0 || system[frame] != 0 { signal = true }
        }
        let micRMS = (micEnergy / Float(count)).squareRoot(), systemRMS = (systemEnergy / Float(count)).squareRoot()

        guard let output = rate == Self.rate ? pcm : resample(pcm, from: rate), (try? file.write(from: output)) != nil else { return }
        if let onChunk, let channels = output.floatChannelData {
            let length = Int(output.frameLength)
            var chunk = Data(count: length * 2 * MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                for frame in 0..<length {
                    samples[frame * 2] = channels[0][frame]
                    samples[frame * 2 + 1] = channels[1][frame]
                }
            }
            pendingPCM.append(chunk)
            let second = Int(Self.rate) * 2 * MemoryLayout<Float>.size
            while pendingPCM.count >= second {
                onChunk(Data(pendingPCM.prefix(second)))
                pendingPCM.removeFirst(second)
            }
        }
        lock.withLock {
            frames += AVAudioFramePosition(output.frameLength)
            microphoneLevel = max(microphoneLevel, micRMS)
            systemLevel = max(systemLevel, systemRMS)
            if max(micRMS, systemRMS) > Self.audibleRMS { lastAudibleFrame = frames }
            if signal { lastSignalFrame = frames }
        }
    }

    func snapshot() -> CaptureSnapshot {
        lock.withLock {
            defer { microphoneLevel = 0; systemLevel = 0 }
            return CaptureSnapshot(
                seconds: Double(frames) / Self.rate, microphone: microphoneLevel, system: systemLevel,
                quietFor: Double(frames - lastAudibleFrame) / Self.rate, deadFor: Double(frames - lastSignalFrame) / Self.rate,
                stalledFor: Date().timeIntervalSince(lastBuffer))
        }
    }

    /// Waits for the last buffer, closes the file and returns the number of frames written.
    func finish() -> AVAudioFramePosition {
        queue.sync {
            sendPending()
            file.close()
            return lock.withLock { frames }
        }
    }

    func flushPending() {
        queue.sync { sendPending() }
    }

    func setChunkHandler(_ handler: (@Sendable (Data) -> Void)?) -> Double {
        queue.sync {
            pendingPCM = Data()
            onChunk = handler
            return lock.withLock { Double(frames) / Self.rate }
        }
    }

    private func sendPending() {
        if !pendingPCM.isEmpty {
            onChunk?(pendingPCM)
            pendingPCM = Data()
        }
    }

    func discard() {
        queue.sync { file.close() }
        try? FileManager.default.removeItem(at: url)
    }

    private func inputFormat(_ rate: Double) -> AVAudioFormat {
        if let known = inputFormats[rate] { return known }
        let made = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        inputFormats[rate] = made
        return made
    }

    private func resample(_ input: AVAudioPCMBuffer, from rate: Double) -> AVAudioPCMBuffer? {
        guard let converter = converters[rate] ?? AVAudioConverter(from: input.format, to: format) else { return nil }
        converters[rate] = converter
        let capacity = AVAudioFrameCount((Double(input.frameLength) * Self.rate / rate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
