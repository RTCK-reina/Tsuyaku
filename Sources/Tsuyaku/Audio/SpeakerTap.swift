import Foundation
import CoreAudio
import AppKit
import Synchronization

/// Captures speaker output ("system audio") via a CoreAudio process tap
/// (macOS 14.2+) wrapped in a private aggregate device, so AVAudioEngine can
/// consume it like any other input device. Optionally stacks the microphone
/// into the same aggregate for full voice-chat capture (mic + remote party).
///
/// The tap is `unmuted` — audio keeps playing to the speakers normally.
final class SpeakerTap: Sendable {

    enum TapError: LocalizedError {
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case appNotRunning(String)
        case micUnavailable

        var errorDescription: String? {
            switch self {
            case .tapFailed(let s):
                return "プロセスタップの作成に失敗しました (status \(s))"
            case .aggregateFailed(let s):
                return "集約デバイスの作成に失敗しました (status \(s))"
            case .appNotRunning(let id):
                return "対象アプリが起動していません: \(id)"
            case .micUnavailable:
                return "マイクデバイスが見つかりません"
            }
        }
    }

    private let state = Mutex(State())
    private struct State {
        var tapID: AudioObjectID = 0
        var aggregateID: AudioObjectID = 0
    }

    /// Create the tap + aggregate device and return its AudioDeviceID.
    /// - Parameters:
    ///   - includeMicUID: UID of a mic device to stack into the aggregate
    ///     (mic + speaker). nil → speaker output only.
    ///   - bundleIDs: when non-empty, tap only these apps (e.g. Discord).
    ///     Empty → tap all system output.
    func start(includeMicUID: String?, bundleIDs: [String]) throws -> AudioDeviceID {
        stop()

        // 1) Process tap description.
        let filtered = bundleIDs.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let desc: CATapDescription
        if filtered.isEmpty {
            // All output, excluding this app itself.
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses:
                                        [selfProcessObjectID()])
        } else if #available(macOS 26.0, *) {
            // Bundle-ID-based taps re-attach automatically when the app
            // restarts (processRestoreEnabled).
            desc = CATapDescription(stereoMixdownOfProcesses: [])
            desc.bundleIDs = filtered
            desc.isProcessRestoreEnabled = true
        } else {
            let objects = processObjectIDs(forBundleIDs: filtered)
            guard !objects.isEmpty else {
                throw TapError.appNotRunning(filtered.joined(separator: ", "))
            }
            desc = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        desc.name = "Tsuyaku Speaker Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        // 2) Create the tap.
        var tapID = AudioObjectID(0)
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != 0 else { throw TapError.tapFailed(status) }

        // 3) Private aggregate device wrapping the tap (+ optional mic).
        let tapUID = desc.uuid.uuidString
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TsuyakuSpeakerTap",
            kAudioAggregateDeviceUIDKey: "tsuyaku.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        // The aggregate's clock master + reference subdevice is the current
        // default output device — that's the stream the tap follows. An
        // optional mic stacks in as an additional subdevice (mic + speaker).
        guard let outputID = AudioDeviceManager.defaultOutputDeviceID(),
              let outputUID = AudioDeviceManager.deviceUID(forID: outputID)
        else { throw TapError.micUnavailable }

        var subdevices: [[String: Any]] = [[
            kAudioSubDeviceUIDKey: outputUID,
            kAudioSubDeviceDriftCompensationKey: true,
        ]]
        if let micUID = includeMicUID {
            subdevices.append([
                kAudioSubDeviceUIDKey: micUID,
                kAudioSubDeviceDriftCompensationKey: true,
            ])
        }
        aggDesc[kAudioAggregateDeviceSubDeviceListKey] = subdevices
        aggDesc[kAudioAggregateDeviceMainSubDeviceKey] =
            includeMicUID ?? outputUID
        aggDesc[kAudioAggregateDeviceIsStackedKey] = includeMicUID != nil

        var aggregateID = AudioObjectID(0)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.aggregateFailed(status)
        }

        if ProcessInfo.processInfo.environment["TSUYAKU_TEST_LIVE"] != nil {
            let ch = AudioDeviceManager.inputChannelCount(for: aggregateID)
            FileHandle.standardError.write(
                "[speakertap] aggID=\(aggregateID) inputChannels=\(ch) outUID=\(outputUID) mic=\(includeMicUID ?? "-")\n"
                    .data(using: .utf8)!)
        }

        state.withLock {
            $0.tapID = tapID
            $0.aggregateID = aggregateID
        }
        return aggregateID
    }

    func stop() {
        let (agg, tap) = state.withLock { s -> (AudioObjectID, AudioObjectID) in
            let v = (s.aggregateID, s.tapID)
            s.aggregateID = 0
            s.tapID = 0
            return v
        }
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    }

    deinit { stop() }

    // MARK: - Process object lookup

    /// pid → AudioObjectID of the process object (HAL object, not the pid).
    private func processObjectID(forPID pid: pid_t) -> AudioObjectID {
        var pidVar = pid
        var objectID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidVar, &dataSize, &objectID)
        return status == noErr ? objectID : 0
    }

    private func selfProcessObjectID() -> AudioObjectID {
        processObjectID(forPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// bundle id → AudioObjectID via NSRunningApplication (macOS < 26 path;
    /// 26+ passes bundle IDs straight to the tap).
    private func processObjectIDs(forBundleIDs bundleIDs: [String]) -> [AudioObjectID] {
        var out: [AudioObjectID] = []
        for bid in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                let obj = processObjectID(forPID: app.processIdentifier)
                if obj != 0 { out.append(obj) }
            }
        }
        return out
    }
}
