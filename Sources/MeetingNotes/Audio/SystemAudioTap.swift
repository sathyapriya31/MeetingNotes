import Foundation
import AudioToolbox
import AVFoundation

/// Bot-free capture of the *other* meeting participants:
/// taps system audio output using Core Audio process taps (macOS 14.4+).
///
/// Flow: CATapDescription (global, excluding no one) → hidden aggregate
/// device that includes the tap → IOProc reads the tapped audio.
///
/// First use triggers the "System Audio Recording" TCC prompt driven by
/// NSAudioCaptureUsageDescription.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var onSamples: (([Float]) -> Void)?
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        self.onSamples = onSamples

        // 1. Tap ALL system output (empty exclusion list), mixed to stereo.
        //    To tap only Zoom/Meet/Teams, resolve their PIDs to audio process
        //    objects and use CATapDescription(processes:) instead.
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted   // user still hears the meeting

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard err == noErr else { throw TapError.osStatus("CreateProcessTap", err) }
        tapID = newTapID

        // 2. Read the tap's stream format.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.osStatus("GetTapFormat", err)
        }
        tapFormat = fmt
        converter = AVAudioConverter(from: fmt, to: MicCapture.targetFormat)

        // 3. Aggregate device wrapping the tap. // CHECK-API: key strings
        //    (kAudioAggregateDevice*) are stable but verify against the SDK.
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetingNotes Tap",
            kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ]
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard err == noErr else { throw TapError.osStatus("CreateAggregateDevice", err) }
        aggregateID = newAggID

        // 4. IOProc pulls tapped audio.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(bufferList: inInputData)
        }
        guard err == noErr else { throw TapError.osStatus("CreateIOProc", err) }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { throw TapError.osStatus("DeviceStart", err) }
    }

    private func handle(bufferList: UnsafePointer<AudioBufferList>) {
        guard let tapFormat, let converter, let onSamples else { return }
        let abl = UnsafeMutablePointer(mutating: bufferList)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: abl, deallocator: nil),
              pcm.frameLength > 0 else { return }

        let ratio = MicCapture.targetFormat.sampleRate / tapFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: MicCapture.targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        converter.convert(to: out, error: nil) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard out.frameLength > 0, let ch = out.floatChannelData else { return }
        onSamples(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    enum TapError: Error, LocalizedError {
        case osStatus(String, OSStatus)
        var errorDescription: String? {
            if case let .osStatus(stage, code) = self { return "\(stage) failed (OSStatus \(code))" }
            return nil
        }
    }
}
