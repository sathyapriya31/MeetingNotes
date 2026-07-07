import Foundation

struct TranscriptSegment: Identifiable, Codable {
    var id = UUID()
    var start: Double          // seconds from meeting start
    var end: Double
    var speaker: String        // "You", "Them", or "Speaker N" after diarization
    var channel: AudioChannel
    var text: String
}

extension String {
    /// Whisper output cleaned for humans: special tokens (`<|en|>`, `<|0.00|>`,
    /// `<|startoftranscript|>`, …) removed, and segments that are only a noise
    /// annotation like "[ Inaudible ]" or "(music)" collapsed to empty.
    var cleanedTranscript: String {
        var t = replacingOccurrences(of: "<\\|[^<>]*?\\|>", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "^[\\[\\(][^\\]\\)]*[\\]\\)]$", options: .regularExpression) != nil { return "" }
        return t
    }
}

/// One completed meeting, persisted to disk by `MeetingStore`.
struct Meeting: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var transcript: [TranscriptSegment]
    var notes: MeetingNotes?
}

struct MeetingNotes: Codable {
    var summary: String
    var keyDecisions: [String]
    var actionItems: [ActionItem]
}

struct ActionItem: Codable, Identifiable {
    let id = UUID()
    var owner: String
    var task: String
    var due: String?
    enum CodingKeys: String, CodingKey { case owner, task, due }
}
