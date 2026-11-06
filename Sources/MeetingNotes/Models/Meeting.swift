import Foundation

struct TranscriptSegment: Identifiable, Codable {
    var id = UUID()
    var start: Double          // seconds from meeting start
    var end: Double
    var speaker: String        // "You", "Them", or "Speaker N • Name"
    var channel: AudioChannel
    var text: String
}

extension String {
    /// Output cleaned for humans: special tokens removed, empty annotations collapsed.
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
    var title: String?
    var date: Date
    var transcript: [TranscriptSegment]
    var notes: MeetingNotes?
    /// Name of the folder this meeting is filed in (`nil` = unfiled).
    var folder: String? = nil
    /// What the user typed in "My Notes", kept as written.
    var userNotes: String? = nil
    /// People on the calendar invite (the user excluded), when one was matched.
    /// Optional so meetings saved before calendar integration still decode.
    var attendees: [String]?
    var calendarEventID: String?
    /// When the meeting was pinned; nil when unpinned.
    var pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let summary = notes?.summary, !summary.isEmpty {
            let firstSentence = summary.components(separatedBy: ".").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !firstSentence.isEmpty && firstSentence.count < 65 {
                return firstSentence
            }
            return String(summary.prefix(50)) + "…"
        }
        return "Meeting on " + date.formatted(date: .abbreviated, time: .shortened)
    }

    var durationMinutes: Int {
        guard let last = transcript.last else { return 1 }
        return max(1, Int(ceil(last.end / 60.0)))
    }

    var uniqueSpeakers: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for seg in transcript {
            if seen.insert(seg.speaker).inserted {
                list.append(seg.speaker)
            }
        }
        return list
    }
}

struct MeetingNotes: Codable {
    var summary: String
    var keyDecisions: [String]
    var actionItems: [ActionItem]
    /// The user's own notes rewritten by the LLM with details from the transcript,
    /// one bullet per entry. `nil` when the user wrote no notes.
    var enhancedNotes: [String]? = nil
}

struct ActionItem: Codable, Identifiable {
    var id = UUID()
    var owner: String
    var task: String
    var due: String?
    var isCompleted: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, owner, task, due, isCompleted
    }

    init(owner: String = "", task: String, due: String? = nil, isCompleted: Bool = false) {
        self.id = UUID()
        self.owner = owner
        self.task = task
        self.due = due
        self.isCompleted = isCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.owner = (try? container.decodeIfPresent(String.self, forKey: .owner)) ?? ""
        self.task = try container.decode(String.self, forKey: .task)
        self.due = try? container.decodeIfPresent(String.self, forKey: .due)
        self.isCompleted = (try? container.decodeIfPresent(Bool.self, forKey: .isCompleted)) ?? false
    }
}
