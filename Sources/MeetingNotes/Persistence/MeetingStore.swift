import Foundation

/// Persists finished meetings as one JSON file each in Application Support,
/// and publishes the list (newest first) for the history sidebar.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("MeetingNotes/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        meetings = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    func save(_ meeting: Meeting) {
        do {
            let data = try JSONEncoder().encode(meeting)
            try data.write(to: fileURL(for: meeting), options: .atomic)
        } catch {
            NSLog("MeetingStore: failed to save meeting \(meeting.id): \(error)")
        }
        meetings.insert(meeting, at: 0)
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: fileURL(for: meeting))
        meetings.removeAll { $0.id == meeting.id }
    }

    private func fileURL(for meeting: Meeting) -> URL {
        directory.appendingPathComponent("\(meeting.id.uuidString).json")
    }
}
