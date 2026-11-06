import Foundation

/// Replaces anonymous diarization labels ("Them", "Speaker 1", …) with names
/// from the calendar invite.
///
/// Voices can't be matched to people from audio alone, so:
/// - one remote voice + one remote attendee → that attendee, directly;
/// - otherwise the LLM proposes a mapping from cues in the transcript (people
///   addressing each other by name, introductions), and `validatedMapping`
///   keeps only answers that name a real attendee, once.
/// Labels without a confident match stay as they are and can be renamed by hand.
enum SpeakerLabeler {

    /// Remote (system-channel) speaker labels, in order of first appearance.
    static func remoteLabels(in segments: [TranscriptSegment]) -> [String] {
        var labels: [String] = []
        for seg in segments where seg.channel == .system && !labels.contains(seg.speaker) {
            labels.append(seg.speaker)
        }
        return labels
    }

    /// The mapping that needs no inference, if the case is unambiguous.
    static func directMapping(labels: [String], attendees: [String]) -> [String: String]? {
        guard labels.count == 1, attendees.count == 1 else { return nil }
        return [labels[0]: attendees[0]]
    }

    /// True when the LLM is worth asking: there are attendees and at least one
    /// label that stands for a single voice. A lone "Them" with several
    /// attendees may be several people merged, so it is left alone.
    static func needsInference(labels: [String], attendees: [String]) -> Bool {
        !attendees.isEmpty && labels.contains { $0 != "Them" }
    }

    /// Cleans an LLM answer: keys must be known labels, values must name an
    /// attendee (exactly, or by a unique first name), and a name proposed for
    /// more than one label is dropped entirely.
    static func validatedMapping(_ raw: [String: String?], labels: [String], attendees: [String]) -> [String: String] {
        var resolved: [String: String] = [:]
        for (label, value) in raw {
            guard labels.contains(label), label != "Them",
                  let value, let name = resolveAttendee(value, in: attendees) else { continue }
            resolved[label] = name
        }
        let counts = Dictionary(grouping: resolved.values, by: { $0 }).mapValues(\.count)
        return resolved.filter { counts[$0.value] == 1 }
    }

    static func apply(_ mapping: [String: String], to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !mapping.isEmpty else { return segments }
        return segments.map { seg in
            guard seg.channel == .system, let name = mapping[seg.speaker] else { return seg }
            var s = seg
            s.speaker = name
            return s
        }
    }

    private static func resolveAttendee(_ value: String, in attendees: [String]) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if let exact = attendees.first(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) {
            return exact
        }
        let byFirstName = attendees.filter {
            ($0.split(separator: " ").first.map(String.init) ?? "").caseInsensitiveCompare(v) == .orderedSame
        }
        return byFirstName.count == 1 ? byFirstName[0] : nil
    }
}
