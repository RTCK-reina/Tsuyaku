import Foundation
import AVFoundation
import CoreAudio

/// Captures mic/line input via AVAudioEngine and emits mono 16 kHz Float32 chunks.
final class AudioCaptureEngine {

    /// Called on a background queue with 16 kHz mono Float32 samples.
    var onAudioChunk: (([Float]) -> Void)?
    /// Called with instantaneous input level (0...1) for the level meter.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000
    private var converter: AVAudioConverter?
    private var outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var running = false
    private var pending = [Float]()
    private let chunkSize = 4096
    private let queue = DispatchQueue(label: "tsuyaku.capture", qos: .userInitiated)
    private var selectedDeviceID: AudioDeviceID?

    /// Device to capture from. Pass nil to follow the system default.
    func start(deviceID: AudioDeviceID?) throws {
        stop()
        selectedDeviceID = deviceID

        let input = engine.inputNode

        if let deviceID {
            var id = deviceID
            let status = AudioUnitSetProperty(
                input.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                throw NSError(domain: "AudioCaptureEngine", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Failed to select input device (\(status))"])
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCaptureEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Input device has no valid input format"])
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        let queue = self.queue
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            queue.async { self.handle(buffer: buffer) }
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running || engine.inputNode.numberOfInputs > 0 else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        pending.removeAll(keepingCapacity: true)
    }

    var isRunning: Bool { running }

    // MARK: - Tap processing

    private var tapDebugCount = 0

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if ProcessInfo.processInfo.environment["TSUYAKU_TEST_LIVE"] != nil,
           tapDebugCount < 8 {
            tapDebugCount += 1
            FileHandle.standardError.write(
                "[capture] frames=\(buffer.frameLength) fmt=\(buffer.format.sampleRate)Hz x\(buffer.format.channelCount)ch err=\(error?.localizedDescription ?? "-") out=\(out.frameLength)\n"
                    .data(using: .utf8)!)
        }
        guard error == nil, out.frameLength > 0,
              let data = out.floatChannelData?[0] else { return }

        // Level meter from the converted signal.
        var peak: Float = 0
        let n = Int(out.frameLength)
        var i = 0
        while i < n {
            let a = abs(data[i])
            if a > peak { peak = a }
            i += 16
        }
        onLevel?(min(1, peak * 1.5))

        pending.append(contentsOf: UnsafeBufferPointer(start: data, count: n))
        while pending.count >= chunkSize {
            let chunk = Array(pending.prefix(chunkSize))
            pending.removeFirst(chunkSize)
            onAudioChunk?(chunk)
        }
    }
}
