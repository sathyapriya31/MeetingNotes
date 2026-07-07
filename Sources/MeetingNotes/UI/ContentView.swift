import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(coordinator.isRecording ? .red : .secondary)
                    .frame(width: 8, height: 8)
                Text(coordinator.status).font(.callout)
            }
            if coordinator.isRecording {
                Button("Stop & Summarize") { Task { await coordinator.stopMeeting() } }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button("Start Meeting Capture") { Task { await coordinator.startMeeting() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            Button("Open Notes Window") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 240)
    }
}

struct ContentView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @EnvironmentObject var store: MeetingStore
    @State private var selectedMeetingID: UUID?

    private var selectedMeeting: Meeting? {
        guard let id = selectedMeetingID else { return nil }
        return store.meetings.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300)

            transcriptPane
                .frame(minWidth: 340)

            notesPane
                .frame(minWidth: 300)
        }
        .frame(minWidth: 900, minHeight: 480)
        .onChange(of: coordinator.isRecording) {
            // Jump back to the live view when a new recording starts.
            if coordinator.isRecording { selectedMeetingID = nil }
        }
        .onChange(of: coordinator.lastSavedMeetingID) {
            // A finished meeting moves to the sidebar — follow it there.
            if let id = coordinator.lastSavedMeetingID { selectedMeetingID = id }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedMeetingID) {
            Section {
                Button {
                    selectedMeetingID = nil
                } label: {
                    Label {
                        Text(coordinator.isRecording ? "Recording…" : "Current Meeting")
                    } icon: {
                        Image(systemName: coordinator.isRecording ? "record.circle.fill" : "waveform")
                            .foregroundStyle(coordinator.isRecording ? .red : Color.accentColor)
                    }
                    .fontWeight(selectedMeetingID == nil ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            }
            Section("Previous Meetings") {
                if store.meetings.isEmpty {
                    Text("Finished meetings appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.meetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                if selectedMeetingID == meeting.id { selectedMeetingID = nil }
                                store.delete(meeting)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Transcript

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: "Transcript",
                subtitle: selectedMeeting.map { $0.date.formatted(date: .abbreviated, time: .shortened) }
                    ?? coordinator.status,
                isLive: selectedMeeting == nil && coordinator.isRecording
            )
            Divider()
            TranscriptList(
                segments: selectedMeeting?.transcript ?? coordinator.liveTranscript,
                autoScrolls: selectedMeeting == nil,
                emptyHint: selectedMeeting == nil
                    ? "Start a meeting to see the live transcript."
                    : "This meeting has no transcript."
            )
        }
    }

    // MARK: Notes

    private var notesPane: some View {
        let notes = selectedMeeting != nil ? selectedMeeting?.notes : coordinator.currentNotes
        return VStack(spacing: 0) {
            PaneHeader(title: "Notes")
            Divider()
            ScrollView {
                if let notes {
                    NotesDetail(notes: notes)
                } else if selectedMeeting != nil {
                    ContentUnavailableView(
                        "No notes for this meeting",
                        systemImage: "doc.text",
                        description: Text("Summarization didn't produce notes.")
                    )
                    .padding(.top, 40)
                } else {
                    ContentUnavailableView(
                        coordinator.isRecording ? "Recording…" : "No notes yet",
                        systemImage: "doc.text",
                        description: Text(coordinator.isRecording
                            ? "Notes are generated when you stop the meeting."
                            : coordinator.status)
                    )
                    .padding(.top, 40)
                }
            }
        }
    }
}

// MARK: - Components

struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil
    var isLive = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            if isLive {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("LIVE").font(.caption2.bold())
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.red.opacity(0.12), in: Capsule())
            }
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                .font(.callout.weight(.medium))
            Text(meeting.notes?.summary ?? "\(meeting.transcript.count) transcript segments")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let autoScrolls: Bool
    let emptyHint: String

    // Cleaned once per render; drops segments that are empty after stripping
    // Whisper tokens (also sanitizes meetings saved before cleaning existed).
    private var visible: [(segment: TranscriptSegment, text: String)] {
        segments.compactMap {
            let text = $0.text.cleanedTranscript
            return text.isEmpty ? nil : ($0, text)
        }
    }

    var body: some View {
        if visible.isEmpty {
            ContentUnavailableView("No transcript", systemImage: "waveform", description: Text(emptyHint))
                .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(visible, id: \.segment.id) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.segment.speaker)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(row.segment))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1.5)
                                .background(speakerColor(row.segment).opacity(0.14), in: Capsule())
                            Text(timestamp(row.segment.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(row.text)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                    .id(row.segment.id)
                }
                .onChange(of: segments.count) {
                    if autoScrolls, let last = visible.last {
                        proxy.scrollTo(last.segment.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func speakerColor(_ seg: TranscriptSegment) -> Color {
        if seg.channel == .mic || seg.speaker == "You" { return .blue }
        let palette: [Color] = [.orange, .green, .purple, .teal, .pink]
        // Stable across launches (String.hashValue isn't).
        let hash = seg.speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[hash % palette.count]
    }

    private func timestamp(_ s: Double) -> String {
        String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct NotesDetail: View {
    let notes: MeetingNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Summary", icon: "text.alignleft") {
                Text(notes.summary).textSelection(.enabled)
            }

            if !notes.keyDecisions.isEmpty {
                section("Key Decisions", icon: "checkmark.seal") {
                    ForEach(notes.keyDecisions, id: \.self) { decision in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(.secondary).frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(decision).textSelection(.enabled)
                        }
                    }
                }
            }

            if !notes.actionItems.isEmpty {
                section("Action Items", icon: "checklist") {
                    ForEach(notes.actionItems) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task).textSelection(.enabled)
                                Text("\(item.owner)\(item.due.map { " — due \($0)" } ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
    }
}
