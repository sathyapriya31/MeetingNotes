import Foundation
import WhisperKit

/// Near-live transcription: buffers each channel and transcribes in ~15 s
/// windows through WhisperKit (Core ML / ANE). Two channels are kept apart
/// so mic = "You" and system = "Them" before diarization even runs.
actor TranscriptionBuffers {
    var mic: [Float] = []
    var system: [Float] = []
    func append(_ s: [Float], to channel: AudioChannel) {
        switch channel { case .mic: mic.append(contentsOf: s); case .system: system.append(contentsOf: s) }
    }
    func drain(_ channel: AudioChannel, keepLast: Int = 0) -> [Float] {
        switch channel {
        case .mic:    let out = mic;    mic    = Array(mic.suffix(keepLast));    return out
        case .system: let out = system; system = Array(system.suffix(keepLast)); return out
        }
    }
}

final class TranscriptionService {
    private var whisper: WhisperKit?
    private let buffers = TranscriptionBuffers()
    private var timer: Timer?
    private var elapsed: [AudioChannel: Double] = [.mic: 0, .system: 0]
    private var allSegments: [TranscriptSegment] = []
    private let windowSeconds: Double = 15
    private let sampleRate: Double = 16_000

    /// Downloads/loads the model on first run. "small" balances speed and
    /// accuracy; use "large-v3-turbo" (still fast on ANE) for best accuracy.
    func prepare() async throws {
        guard whisper == nil else { return }
        whisper = try await WhisperKit(WhisperKitConfig(model: "small"))  // CHECK-API
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
            // Keep 1 s of overlap to avoid cutting words at window edges.
            let audio = await buffers.drain(channel, keepLast: Int(sampleRate))
            guard audio.count > Int(sampleRate) else { continue }   // skip < 1 s

            let base = elapsed[channel] ?? 0
            elapsed[channel] = base + Double(audio.count) / sampleRate

            guard let whisper else { continue }
            do {
                let results = try await whisper.transcribe(audioArray: audio)  // CHECK-API
                for r in results {
                    for seg in r.segments {
                        let text = seg.text.cleanedTranscript
                        guard !text.isEmpty else { continue }
                        let segment = TranscriptSegment(
                            start: base + Double(seg.start),
                            end: base + Double(seg.end),
                            speaker: channel == .mic ? "You" : "Them",
                            channel: channel,
                            text: text
                        )
                        allSegments.append(segment)
                        onSegment(segment)
                    }
                }
            } catch {
                print("Transcription window failed: \(error)")
            }
        }
    }

    /// Flush remaining audio and return everything.
    func finish() async -> [TranscriptSegment] {
        timer?.invalidate(); timer = nil
        await transcribePending(onSegment: { _ in })
        return allSegments
    }
}
