import Foundation
import FluidAudio

/// Post-meeting speaker diarization on the *system* channel only —
/// the mic channel is already known to be "You".
/// Offline diarization after the call is markedly more accurate than online.
final class DiarizationService {

    func diarize(
        micSamples: [Float],
        systemSamples: [Float],
        segments: [TranscriptSegment]
    ) async -> [TranscriptSegment] {
        guard systemSamples.count > 16_000 else { return segments }

        do {
            // CHECK-API: verify against the FluidAudio release you pin.
            let models = try await DiarizerModels.downloadIfNeeded()
            let diarizer = DiarizerManager()
            diarizer.initialize(models: models)
            let result = try diarizer.performCompleteDiarization(
                systemSamples, sampleRate: 16_000
            )

            // Map each "Them" transcript segment to the diarizer turn with
            // the largest time overlap.
            return segments.map { seg in
                guard seg.channel == .system else { return seg }
                var best: (overlap: Double, speaker: String)? = nil
                for turn in result.segments {
                    let overlap = min(seg.end, Double(turn.endTimeSeconds))
                                - max(seg.start, Double(turn.startTimeSeconds))
                    if overlap > 0, overlap > (best?.overlap ?? 0) {
                        best = (overlap, "Speaker \(turn.speakerId)")
                    }
                }
                var updated = seg
                updated.speaker = best?.speaker ?? "Them"
                return updated
            }
        } catch {
            print("Diarization failed, keeping You/Them labels: \(error)")
            return segments
        }
    }
}
