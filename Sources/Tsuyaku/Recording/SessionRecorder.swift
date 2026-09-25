import Foundation
import AVFoundation

/// Writes the 16 kHz mono stream to a WAV file + JSON sidecar with session metadata.
final class SessionRecorder {

    struct SessionMeta: Codable {
        var id: String
        var startedAt: Date
        var endedAt: Date?
        var deviceName: String
        var mode: PerformanceMode
        var durationSeconds: Double
        var wavFile: String
    }

    private var file: AVAudioFile?
    private var meta: SessionMeta?
    private var startTime: Date?
    private var framesWritten: AVAudioFramePosition = 0
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private(set) var currentURL: URL?
    private let lock = NSLock()

    var isRecording: Bool { file != nil }

    func start(deviceName: String, mode: PerformanceMode) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        _ = stopLocked()

        let dir = AppSettings.recordingsDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = DateFormatter.filenameStamp.string(from: Date())
        let id = UUID().uuidString.prefix(8)
        let wavURL = dir.appendingPathComponent("session_\(stamp)_\(id).wav")
        let audioFile = try AVAudioFile(forWriting: wavURL, settings: format.settings)

        file = audioFile
        currentURL = wavURL
        startTime = Date()
        framesWritten = 0
        meta = SessionMeta(
            id: String(id), startedAt: Date(), endedAt: nil,
            deviceName: deviceName, mode: mode, durationSeconds: 0,
            wavFile: wavURL.lastPathComponent)
        return wavURL
    }

    /// Append 16 kHz mono samples.
    func write(samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // Drop the chunk silently; recording must never break the live path.
        }
    }

    @discardableResult
    func stop() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return stopLocked()
    }

    private func stopLocked() -> URL? {
        guard let url = currentURL else { return nil }
        file = nil
        currentURL = nil
        if var meta {
            meta.endedAt = Date()
            meta.durationSeconds = Double(framesWritten) / 16000.0
            let metaURL = url.deletingPathExtension().appendingPathExtension("json")
            if let data = try? JSONEncoder.pretty.encode(meta) {
                try? data.write(to: metaURL)
            }
        }
        meta = nil
        return url
    }

    /// List recorded sessions (wav + meta).
    static func listSessions() -> [(wav: URL, meta: SessionMeta?)] {
        let dir = AppSettings.recordingsDir
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "wav" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            .map { wav in
                let metaURL = wav.deletingPathExtension().appendingPathExtension("json")
                let meta = try? JSONDecoder().decode(
                    SessionMeta.self, from: Data(contentsOf: metaURL))
                return (wav, meta)
            }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension DateFormatter {
    static let filenameStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
