import Foundation
import AVFoundation
import CoreAudio

/// Reads audio from an aggregate device (e.g. a process-tap aggregate for
/// speaker capture) via a HAL IOProc block. AVAudioEngine's inputNode does not
/// deliver buffers for tap aggregates, so IO is driven at the device level —
/// this is the same path process-tap implementations use.
final class TapCaptureEngine {

    /// Called on the IO thread with 16 kHz mono Float32 samples.
    var onAudioChunk: (([Float]) -> Void)?
    /// Called with instantaneous input level (0...1) for the level meter.
    var onLevel: ((Float) -> Void)?

    private var deviceID = AudioObjectID(0)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var bytesPerFrame = 0
    private var pending = [Float]()
    private let chunkSize = 4096
    private let lock = NSLock()
    private var debugCount = 0

    func start(deviceID: AudioObjectID) throws {
        stop()
        self.deviceID = deviceID

        // Input-side stream format of the aggregate.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw Self.err("タップデバイスのフォーマット取得に失敗 (\(status))", status)
        }
        guard let inFmt = AVAudioFormat(streamDescription: &asbd) else {
            throw Self.err("タップデバイスのフォーマットが非対応です", -1)
        }
        inputFormat = inFmt
        bytesPerFrame = Int(asbd.mBytesPerFrame)
        converter = AVAudioConverter(from: inFmt, to: outputFormat)

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, deviceID, nil
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handle(abl: inInputData)
        }
        guard status == noErr, let procID else {
            throw Self.err("IOProc の作成に失敗 (\(status))", status)
        }
        ioProcID = procID

        status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
            throw Self.err("タップデバイスの開始に失敗 (\(status))", status)
        }
        running = true
    }

    func stop() {
        if let proc = ioProcID {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
            ioProcID = nil
        }
        running = false
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    var isRunning: Bool { running }

    // MARK: - IO callback (realtime thread — keep it cheap)

    private func handle(abl: UnsafePointer<AudioBufferList>) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let inputFormat, bytesPerFrame > 0 else { return }

        let srcList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: abl))
        guard let first = srcList.first, first.mData != nil,
              first.mDataByteSize > 0 else { return }
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard frames > 0 else { return }

        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        let dstList = UnsafeMutableAudioBufferListPointer(inBuf.mutableAudioBufferList)
        for (i, src) in srcList.enumerated() where i < dstList.count {
            guard let d = dstList[i].mData, let s = src.mData else { continue }
            let n = min(Int(src.mDataByteSize), Int(dstList[i].mDataByteSize))
            memcpy(d, s, n)
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if ProcessInfo.processInfo.environment["TSUYAKU_TEST_LIVE"] != nil,
           debugCount < 8 {
            debugCount += 1
            FileHandle.standardError.write(
                "[tapcap] frames=\(frames) fmt=\(inputFormat.sampleRate)Hz x\(inputFormat.channelCount)ch err=\(error?.localizedDescription ?? "-") out=\(out.frameLength)\n"
                    .data(using: .utf8)!)
        }
        guard error == nil, out.frameLength > 0,
              let data = out.floatChannelData?[0] else { return }

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

    private static func err(_ msg: String, _ status: OSStatus) -> NSError {
        NSError(domain: "TapCaptureEngine", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
