import Foundation
import FluidAudio

/// Identifies the speaker of a single utterance by extracting its embedding and
/// matching it against a session-long speaker registry.
actor SpeakerTracker {

    enum State: Sendable {
        case idle, preparing, ready, failed(String)
    }

    private var manager: DiarizerManager?
    private var speakerManager = SpeakerManager()
    private(set) var state: State = .idle

    /// Stable display names assigned in order of first appearance.
    private var labels: [String: String] = [:]
    private var nextLabelIndex = 0

    private static let japaneseLabels = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

    func prepare() async throws {
        if manager != nil { return }
        state = .preparing
        do {
            let models = try await DiarizerModels.load()
            let mgr = DiarizerManager()
            mgr.initialize(models: models)
            manager = mgr
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func reset() {
        speakerManager.reset()
        labels.removeAll()
        nextLabelIndex = 0
    }

    /// Returns a stable speaker label ("話者A", ...) or nil when unavailable.
    func identify(samples: [Float]) -> String? {
        guard let manager, manager.isAvailable else { return nil }
        let duration = Float(samples.count) / 16000.0
        guard duration >= 0.4 else { return nil }  // too short for a usable embedding

        guard let embedding = try? manager.extractSpeakerEmbedding(from: samples) else {
            return nil
        }
        guard let speaker = speakerManager.assignSpeaker(
            embedding, speechDuration: duration
        ) else { return nil }

        if let existing = labels[speaker.id] { return existing }
        let idx = min(nextLabelIndex, Self.japaneseLabels.count - 1)
        let label = "話者\(Self.japaneseLabels[idx])"
        labels[speaker.id] = label
        nextLabelIndex += 1
        return label
    }

    var speakerCount: Int { speakerManager.speakerCount }
}
