import AVFoundation

/// Captures the user's microphone via AVAudioEngine and delivers
/// 16 kHz mono Float32 samples — the format Whisper/VAD/diarization expect.
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

            var consumed = false
            converter.convert(to: out, error: nil) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let ch = out.floatChannelData else { return }
            onSamples(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
