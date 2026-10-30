import Foundation
import Who

/// Post-meeting speaker diarization on the *system* channel using Desert Ant Labs "Who".
/// The mic channel is already hardware-isolated as "You".
/// "Who" processes the system channel audio on-device using the Apple Neural Engine
/// and segments it into distinct speaker turns with millisecond timestamps.
final class DiarizationService {
    private let who = Who()
    private var isWarmedUp = false

    /// Prepares the Who model and pre-warms the Neural Engine graphs so post-meeting
    /// diarization runs in near-realtime (~1-2 seconds) rather than compiling on stop.
    /// `progress` receives the download fraction (0...1).
    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !isWarmedUp else { return }
        if !who.isDownloaded() {
            try await who.download(progress: progress)
        }
        // Pre-warm the 5 Core ML graphs ahead of time with a 1-second sample
        _ = try? await who.diarize(
            samples: [Float](repeating: 0, count: 16_000),
            sampleRate: 16_000.0
        )
        isWarmedUp = true
    }

    func diarize(
        micSamples: [Float],
        systemSamples: [Float],
        segments: [TranscriptSegment]
    ) async -> [TranscriptSegment] {
        // Fast-path: If no remote audio was transcribed or system audio is too short,
        // all segments are already "You". Skip diarization instantly!
        let systemSegments = segments.filter { $0.channel == .system }
        guard !systemSegments.isEmpty, systemSamples.count > 16_000 else {
            return segments
        }

        do {
            // Trim system audio to the active range of conversation (plus 2s padding)
            // to avoid wasting Neural Engine cycles analyzing trailing silence.
            let maxEndTime = (systemSegments.map(\.end).max() ?? 0) + 2.0
            let sampleLimit = min(systemSamples.count, Int(maxEndTime * 16_000.0))
            let activeSamples = Array(systemSamples.prefix(sampleLimit))

            guard activeSamples.count > 16_000 else { return segments }

            // Run on-device diarization on Neural Engine (16 kHz mono)
            let diarization = try await who.diarize(
                samples: activeSamples,
                sampleRate: 16_000.0
            ).keepingSpeakers(minimumShare: 0.04) // Filter out transient noises / coughs

            // Map each "Them" transcript segment to the Who turn with the greatest time overlap.
            var assigned: [UUID: Int] = [:]
            for seg in systemSegments {
                var bestSpeaker: Int? = nil
                var bestScore = -Double.infinity
                for turn in diarization.turns {
                    let overlap = min(seg.end, turn.end) - max(seg.start, turn.start)
                    let mid = (seg.start + seg.end) / 2.0
                    let score = overlap > 0 ? overlap : -min(abs(mid - turn.start), abs(mid - turn.end))
                    if score > bestScore {
                        bestScore = score
                        bestSpeaker = turn.speaker
                    }
                }
                if let bestSpeaker { assigned[seg.id] = bestSpeaker }
            }

            // Who numbers speakers 0, 1, 2... in order of first appearance.
            // If multiple distinct remote speakers exist, label them "Speaker 1", "Speaker 2", etc.
            // If only one remote voice was detected, keep label as "Them" alongside "You".
            let uniqueSpeakers = Set(assigned.values)
            let hasMultipleRemoteSpeakers = uniqueSpeakers.count > 1

            return segments.map { seg in
                guard seg.channel == .system else { return seg }
                var updated = seg
                if let speakerId = assigned[seg.id] {
                    updated.speaker = hasMultipleRemoteSpeakers ? "Speaker \(speakerId + 1)" : "Them"
                } else {
                    updated.speaker = "Them"
                }
                return updated
            }
        } catch {
            print("Who diarization failed or timed out, retaining default You/Them labels: \(error)")
            return segments
        }
    }
}
