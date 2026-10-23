import Foundation
import Voz

/// Near-live transcription using Desert Ant Labs "Voz" (running on Apple Neural Engine).
/// Buffers each channel and transcribes in ~10 s windows.
/// Two channels are kept apart so mic = "You" and system = "Them" before diarization runs.
actor TranscriptionBuffers {
    var mic: [Float] = []
    var system: [Float] = []
    func append(_ s: [Float], to channel: AudioChannel) {
        switch channel {
        case .mic: mic.append(contentsOf: s)
        case .system: system.append(contentsOf: s)
        }
    }
    func drain(_ channel: AudioChannel, keepLast: Int = 0) -> [Float] {
        switch channel {
        case .mic:
            let out = mic
            mic = Array(mic.suffix(keepLast))
            return out
        case .system:
            let out = system
            system = Array(system.suffix(keepLast))
            return out
        }
    }
}

final class TranscriptionService {
    private var voz: Voz?
    private let buffers = TranscriptionBuffers()
    private var timer: Timer?
    private var elapsed: [AudioChannel: Double] = [.mic: 0, .system: 0]
    private var allSegments: [TranscriptSegment] = []
    private let windowSeconds: Double = 3.0
    private let overlapSeconds: Double = 0.5
    private let sampleRate: Double = 16_000

    /// Loads the Voz model on the Apple Neural Engine, downloading it if not present.
    func prepare() async throws {
        guard voz == nil else { return }
        if !Voz.isDownloaded() {
            try await Voz.download()
        }
        voz = try await Voz()
    }

    func feed(_ samples: [Float], channel: AudioChannel, onSegment: @escaping (TranscriptSegment) -> Void) {
        Task { await buffers.append(samples, to: channel) }
        if timer == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.timer == nil else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: self.windowSeconds, repeats: true) { _ in
                    Task { await self.transcribePending(onSegment: onSegment) }
                }
            }
        }
    }

    private func transcribePending(onSegment: @escaping (TranscriptSegment) -> Void) async {
        for channel in [AudioChannel.mic, .system] {
            let audio = await buffers.drain(channel, keepLast: Int(sampleRate * overlapSeconds))
            guard audio.count > Int(sampleRate * 0.5) else { continue } // skip < 0.5 s

            let base = elapsed[channel] ?? 0
            let kept = min(audio.count, Int(sampleRate * overlapSeconds))
            elapsed[channel] = base + Double(audio.count - kept) / sampleRate

            guard let voz else { continue }
            do {
                let result = try await voz.transcribe(samples: audio)
                let text = result.text.cleanedTranscript
                guard !text.isEmpty else { continue }

                let start = base
                let end = base + Double(audio.count) / sampleRate
                let speaker = channel == .mic ? "You" : "Them"

                let segment = TranscriptSegment(
                    start: start,
                    end: end,
                    speaker: speaker,
                    channel: channel,
                    text: text
                )
                allSegments.append(segment)
                onSegment(segment)
            } catch {
                print("Voz transcription error on channel \(channel): \(error)")
            }
        }
    }

    /// Flush remaining audio and return all transcribed segments.
    func finish() async -> [TranscriptSegment] {
        timer?.invalidate()
        timer = nil
        await transcribePending(onSegment: { _ in })
        return allSegments
    }
}
