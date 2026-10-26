import Foundation

/// Persists finished meetings as one JSON file each in Application Support,
/// and publishes the list (newest first) for the history sidebar.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    /// EmbeddingGemma-backed index used for "search by meaning" in the sidebar.
    let semanticSearch: SemanticSearchService

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MeetingNotes/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        semanticSearch = SemanticSearchService(
            directory: base.appendingPathComponent("MeetingNotes", isDirectory: true)
        )
        load()
    }

    /// Re-indexes in the background; unchanged meetings are skipped cheaply.
    private func refreshSemanticIndex() {
        let snapshot = meetings
        let search = semanticSearch
        Task.detached(priority: .utility) {
            await search.sync(with: snapshot)
        }
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        meetings = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
        refreshSemanticIndex()
    }

    func save(_ meeting: Meeting) {
        do {
            let data = try JSONEncoder().encode(meeting)
            try data.write(to: fileURL(for: meeting), options: .atomic)
        } catch {
            NSLog("MeetingStore: failed to save meeting \(meeting.id): \(error)")
        }
        meetings.insert(meeting, at: 0)
        refreshSemanticIndex()
    }

    func update(_ meeting: Meeting) {
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
        do {
            let data = try JSONEncoder().encode(meeting)
            try data.write(to: fileURL(for: meeting), options: .atomic)
        } catch {
            NSLog("MeetingStore: failed to update meeting \(meeting.id): \(error)")
        }
        refreshSemanticIndex()
    }

    func renameSpeaker(in meetingID: UUID, from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        meeting.transcript = meeting.transcript.map { seg in
            if seg.speaker == oldName {
                var s = seg
                s.speaker = trimmed
                return s
            }
            return seg
        }

        // Also update any action items owned by oldName
        if var notes = meeting.notes {
            notes.actionItems = notes.actionItems.map { item in
                if item.owner == oldName {
                    var updated = item
                    updated.owner = trimmed
                    return updated
                }
                return item
            }
            meeting.notes = notes
        }

        update(meeting)
    }

    func renameTitle(in meetingID: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        meeting.title = trimmed
        update(meeting)
    }

    func toggleActionItem(in meetingID: UUID, itemID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        guard var notes = meeting.notes else { return }
        notes.actionItems = notes.actionItems.map { item in
            if item.id == itemID {
                var updated = item
                updated.isCompleted.toggle()
                return updated
            }
            return item
        }
        meeting.notes = notes
        update(meeting)
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: fileURL(for: meeting))
        meetings.removeAll { $0.id == meeting.id }
        refreshSemanticIndex()
    }

    func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
        meetings.removeAll()
        refreshSemanticIndex()
    }

    private func fileURL(for meeting: Meeting) -> URL {
        directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }
}
