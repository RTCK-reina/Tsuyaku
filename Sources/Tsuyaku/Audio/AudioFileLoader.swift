import Foundation
import AVFoundation

/// Decodes any AVAudioFile-readable file into mono 16 kHz Float32 samples.
enum AudioFileLoader {

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000, channels: 1, interleaved: false)!

        // Read the whole file into a processing-format buffer.
        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "AudioFileLoader", code: -1)
        }
        try file.read(into: inBuf)
        guard inBuf.frameLength > 0 else { return [] }

        // Fast path: already 16 kHz mono Float32.
        if file.processingFormat.sampleRate == 16000,
           file.processingFormat.channelCount == 1,
           file.processingFormat.commonFormat == .pcmFormatFloat32,
           let p = inBuf.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: p, count: Int(inBuf.frameLength)))
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "AudioFileLoader", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
            throw NSError(domain: "AudioFileLoader", code: -3)
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if let error { throw error }
        guard let p = outBuf.floatChannelData?[0], outBuf.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
    }

    static func durationSeconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
