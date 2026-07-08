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
            // the largest time overlap. A segment that overlaps no turn
            // (diarizer gaps, slight timing skew) takes the *nearest* turn —
            // falling back to "Them" per segment would mix two label schemes
            // in one transcript.
            var assigned: [UUID: String] = [:]
            for seg in segments where seg.channel == .system {
                var bestId: String? = nil
                var bestScore = -Double.infinity
                for turn in result.segments {
                    let start = Double(turn.startTimeSeconds)
                    let end = Double(turn.endTimeSeconds)
                    let overlap = min(seg.end, end) - max(seg.start, start)
                    let mid = (seg.start + seg.end) / 2
                    let score = overlap > 0 ? overlap : -min(abs(mid - start), abs(mid - end))
                    if score > bestScore {
                        bestScore = score
                        bestId = "\(turn.speakerId)"
                    }
                }
                if let bestId { assigned[seg.id] = bestId }
            }

            // Raw diarizer IDs are arbitrary ("Speaker 2" with no Speaker 1).
            // Renumber by first appearance; a single remote voice just stays
            // "Them" alongside the mic's "You".
            var labelFor: [String: String] = [:]
            if Set(assigned.values).count > 1 {
                for seg in segments.sorted(by: { $0.start < $1.start }) {
                    guard let id = assigned[seg.id], labelFor[id] == nil else { continue }
                    labelFor[id] = "Speaker \(labelFor.count + 1)"
                }
            }

            return segments.map { seg in
                guard seg.channel == .system else { return seg }
                var updated = seg
                updated.speaker = assigned[seg.id].flatMap { labelFor[$0] } ?? "Them"
                return updated
            }
        } catch {
            print("Diarization failed, keeping You/Them labels: \(error)")
            return segments
        }
    }
}
