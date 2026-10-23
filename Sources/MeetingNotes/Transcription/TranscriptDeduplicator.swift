import Foundation

/// Post-transcription filter that removes mic-channel segments which are
/// near-duplicates of system-channel segments. This catches bleed-through
/// that the VAD didn't suppress — e.g., when the user briefly speaks over
/// a remote participant and both channels produce similar text.
///
/// **Algorithm**:
/// 1. For each mic-channel segment, scan system-channel segments within a
///    ±2 second time window.
/// 2. Compute normalised Levenshtein similarity between the two texts.
/// 3. If similarity ≥ 70 %, drop the mic copy — the system channel is the
///    authoritative source for remote voices.
/// 4. Because each channel is cut into its own 3 s windows, a bleed segment
///    often straddles two system segments. So also drop a mic segment when
///    ≥ 60 % of its words appear in the system text spoken within ±3 s.
enum TranscriptDeduplicator {

    /// Maximum time gap (seconds) between segment midpoints for two segments
    /// to be considered potential duplicates.
    private static let timeWindowSeconds: Double = 2.0

    /// Minimum text similarity (0.0–1.0) to classify as a duplicate.
    private static let similarityThreshold: Double = 0.70

    /// Seconds of system speech around a mic segment searched for its words.
    private static let containmentWindowSeconds: Double = 3.0

    /// Fraction of a mic segment's words that must appear in nearby system speech.
    private static let containmentThreshold: Double = 0.60

    /// Remove mic-channel segments that duplicate system-channel segments.
    ///
    /// - Parameter segments: The full transcript, sorted by start time.
    /// - Returns: Cleaned transcript with bleed-through duplicates removed.
    static func deduplicate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let systemSegments = segments.filter { $0.channel == .system }
        guard !systemSegments.isEmpty else { return segments }

        var dropIDs: Set<UUID> = []

        for seg in segments where seg.channel == .mic {
            let micMid = (seg.start + seg.end) / 2
            let micText = seg.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !micText.isEmpty else { continue }

            let nearbyWords = Set(systemSegments
                .filter { $0.end >= seg.start - containmentWindowSeconds && $0.start <= seg.end + containmentWindowSeconds }
                .flatMap { words($0.text) })
            let micWords = words(seg.text)
            if micWords.count >= 2 {
                let contained = micWords.filter { nearbyWords.contains($0) }.count
                if Double(contained) / Double(micWords.count) >= containmentThreshold {
                    dropIDs.insert(seg.id)
                    continue
                }
            }

            for sys in systemSegments {
                let sysMid = (sys.start + sys.end) / 2
                guard abs(micMid - sysMid) <= timeWindowSeconds else { continue }

                let sysText = sys.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sysText.isEmpty else { continue }

                let similarity = normalizedSimilarity(micText, sysText)
                if similarity >= similarityThreshold {
                    dropIDs.insert(seg.id)
                    break  // no need to check more system segments for this mic seg
                }
            }
        }

        return segments.filter { !dropIDs.contains($0.id) }
    }

    // MARK: - Text Similarity

    /// Lowercased words with surrounding punctuation stripped.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Normalised similarity between two strings: `1 - (editDistance / maxLength)`.
    /// Returns 1.0 for identical strings, 0.0 for completely different ones.
    private static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = levenshteinDistance(Array(a), Array(b))
        return 1.0 - Double(dist) / Double(maxLen)
    }

    /// Classic dynamic-programming Levenshtein distance.
    /// Uses O(min(m,n)) space via a single-row optimisation.
    private static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        // Keep the shorter array as columns for space efficiency.
        let (short, long) = m <= n ? (a, b) : (b, a)
        let sLen = short.count, lLen = long.count

        var prev = Array(0...sLen)
        var curr = [Int](repeating: 0, count: sLen + 1)

        for i in 1...lLen {
            curr[0] = i
            for j in 1...sLen {
                let cost = long[i - 1] == short[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,          // deletion
                    curr[j - 1] + 1,      // insertion
                    prev[j - 1] + cost     // substitution
                )
            }
            swap(&prev, &curr)
        }

        return prev[sLen]
    }
}
