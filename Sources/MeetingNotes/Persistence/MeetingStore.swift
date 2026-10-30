import Foundation

/// Persists finished meetings as one JSON file each in Application Support,
/// and publishes the list (newest first) for the history sidebar.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    /// Folder names, sorted. Kept in `folders.json` so empty folders survive a relaunch.
    @Published private(set) var folders: [String] = []

    /// EmbeddingGemma-backed index used for "search by meaning" in the sidebar.
    let semanticSearch: SemanticSearchService

    private let directory: URL
    private let foldersURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MeetingNotes/Meetings", isDirectory: true)
        foldersURL = base.appendingPathComponent("MeetingNotes/folders.json")
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
        let saved = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: foldersURL))) ?? []
        // Also pick up folders referenced by meetings, in case folders.json was lost.
        setFolders(saved + meetings.compactMap(\.folder))
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

    func updateUserNotes(in meetingID: UUID, to text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        let newValue = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard meeting.userNotes != newValue else { return }
        meeting.userNotes = newValue
        update(meeting)
    }

    /// Pinned meetings, newest first.
    var pinnedMeetings: [Meeting] {
        meetings.filter(\.isPinned)
    }

    func togglePin(in meetingID: UUID) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        meeting.pinnedAt = meeting.isPinned ? nil : Date()
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

    // MARK: Folders

    /// Creates the folder if needed and returns its name (`nil` if `name` is blank).
    @discardableResult
    func createFolder(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let existing = folders.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        setFolders(folders + [trimmed])
        return trimmed
    }

    func renameFolder(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != oldName,
              !folders.contains(where: { $0 != oldName && $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        setFolders(folders.map { $0 == oldName ? trimmed : $0 })
        for meeting in meetings where meeting.folder == oldName {
            var updated = meeting
            updated.folder = trimmed
            update(updated)
        }
    }

    /// Removes the folder. Its meetings are deleted too when `deletingMeetings`
    /// is true; otherwise they are kept and become unfiled.
    func deleteFolder(_ name: String, deletingMeetings: Bool) {
        setFolders(folders.filter { $0 != name })
        for meeting in meetings where meeting.folder == name {
            if deletingMeetings {
                delete(meeting)
            } else {
                var updated = meeting
                updated.folder = nil
                update(updated)
            }
        }
    }

    func moveMeeting(_ meetingID: UUID, toFolder folder: String?) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        var meeting = meetings[index]
        meeting.folder = folder.flatMap { createFolder($0) }
        update(meeting)
    }

    private func setFolders(_ names: [String]) {
        var seen = Set<String>()
        folders = names
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        do {
            try JSONEncoder().encode(folders).write(to: foldersURL, options: .atomic)
        } catch {
            NSLog("MeetingStore: failed to save folders: \(error)")
        }
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
