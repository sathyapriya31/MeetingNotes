import SwiftUI
import AppKit

// MARK: - Design System & Theme

enum Theme {
    static let bgApp = Color(red: 0.05, green: 0.07, blue: 0.09)           // #0D1117
    static let bgSidebar = Color(red: 0.07, green: 0.09, blue: 0.12)       // #121620
    static let bgSurface = Color(red: 0.09, green: 0.12, blue: 0.16)       // #171D27
    static let bgCard = Color(red: 0.10, green: 0.13, blue: 0.18)          // #1A202C
    static let bgCardActive = Color(red: 0.12, green: 0.17, blue: 0.25)    // #1F2C40
    static let borderSubtle = Color.white.opacity(0.08)
    static let borderActive = Color(red: 0.25, green: 0.50, blue: 0.95)

    static let primaryBlue = Color(red: 0.22, green: 0.48, blue: 0.96)     // #387BF6
    static let cyanWave = Color(red: 0.15, green: 0.75, blue: 0.90)        // #26BFE6
    static let greenLocal = Color(red: 0.18, green: 0.75, blue: 0.48)      // #2EBF7A
    static let purpleSpeaker = Color(red: 0.68, green: 0.38, blue: 0.88)   // #AE61E0
    static let redRecording = Color(red: 0.94, green: 0.28, blue: 0.33)    // #F04754
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(coordinator.isRecording ? Theme.redRecording : .secondary)
                    .frame(width: 8, height: 8)
                Text(coordinator.status)
                    .font(.system(size: 13, weight: .medium))
            }
            if coordinator.isRecording {
                Button("Stop & Summarize") { Task { await coordinator.stopMeeting() } }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button("Start Meeting Capture") { Task { await coordinator.startMeeting() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
            Button("Open Meeting Notes") {
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

// MARK: - Main ContentView

struct ContentView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @EnvironmentObject var store: MeetingStore

    @State private var selectedMeetingID: UUID?
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var selectedSpeakerFilter: String? = nil
    @State private var isRenamingTitle = false
    @State private var newTitleText = ""
    @State private var copiedAlert = false
    @State private var liveMeetingTitle = "Business Meetings, Career Visibility & Non-Native Speakers"

    private var selectedMeeting: Meeting? {
        guard let id = selectedMeetingID else { return nil }
        return store.meetings.first { $0.id == id }
    }

    private var isLive: Bool {
        selectedMeetingID == nil
    }

    private var currentTitle: String {
        if let meeting = selectedMeeting {
            return meeting.displayTitle
        }
        return liveMeetingTitle
    }

    private var filteredPreviousMeetings: [Meeting] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return store.meetings
        }
        let q = trimmed.lowercased()
        return store.meetings.filter { meeting in
            // 1. Title & Display Title
            if meeting.displayTitle.lowercased().contains(q) { return true }
            if let title = meeting.title, title.lowercased().contains(q) { return true }

            // 2. Date & Time (formatted variations)
            let dateCard = (meeting.date.formatted(.dateTime.day().month(.abbreviated).year()) + " at " + meeting.date.formatted(.dateTime.hour().minute())).lowercased()
            let dateAbbr = meeting.date.formatted(date: .abbreviated, time: .shortened).lowercased()
            let dateLong = meeting.date.formatted(date: .long, time: .shortened).lowercased()
            let dateNumeric = meeting.date.formatted(date: .numeric, time: .shortened).lowercased()
            if dateCard.contains(q) || dateAbbr.contains(q) || dateLong.contains(q) || dateNumeric.contains(q) {
                return true
            }

            // 3. Speakers (names, initials, or count phrase)
            if meeting.uniqueSpeakers.contains(where: { $0.lowercased().contains(q) }) { return true }
            if "\(meeting.uniqueSpeakers.count) speakers".contains(q) || "\(meeting.uniqueSpeakers.count) speaker".contains(q) { return true }

            // 4. Notes: Summary, Key Decisions, Action Items (task & owner)
            if let notes = meeting.notes {
                if notes.summary.lowercased().contains(q) { return true }
                if notes.keyDecisions.contains(where: { $0.lowercased().contains(q) }) { return true }
                if notes.actionItems.contains(where: {
                    $0.task.lowercased().contains(q) || $0.owner.lowercased().contains(q)
                }) {
                    return true
                }
            }

            // 5. Transcript text & segment speakers
            if meeting.transcript.contains(where: { $0.text.lowercased().contains(q) || $0.speaker.lowercased().contains(q) }) {
                return true
            }

            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Window Header Bar
            headerBar
                .frame(height: 48)
                .background(Theme.bgApp)
                .overlay(alignment: .bottom) {
                    Divider().background(Theme.borderSubtle)
                }

            // Main 3-Pane Layout
            HStack(spacing: 0) {
                // Left Column: Sidebar
                sidebarPane
                    .frame(width: 290)
                    .background(Theme.bgSidebar)
                    .overlay(alignment: .trailing) {
                        Divider().background(Theme.borderSubtle)
                    }

                // Center Column: Transcript
                transcriptPane
                    .frame(minWidth: 420)
                    .background(Theme.bgApp)

                // Right Column: AI Insights
                insightsPane
                    .frame(width: 350)
                    .background(Theme.bgSidebar)
                    .overlay(alignment: .leading) {
                        Divider().background(Theme.borderSubtle)
                    }
            }
        }
        .frame(minWidth: 1060, minHeight: 680)
        .preferredColorScheme(.dark)
        .background(KeyWindowEnforcer())
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            if selectedMeetingID == nil, let first = store.meetings.first {
                selectedMeetingID = first.id
            }
        }
        .onChange(of: coordinator.isRecording) {
            if coordinator.isRecording {
                selectedMeetingID = nil
            }
        }
        .onChange(of: coordinator.lastSavedMeetingID) {
            if let id = coordinator.lastSavedMeetingID {
                selectedMeetingID = id
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 0) {
            // Left spacer to clear traffic lights
            Spacer()
                .frame(width: 76)

            // Centered Title: 🎙️ Meeting Notes / Oct 22, 2026
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primaryBlue)

                Text("Meeting Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))

                Text(Date().formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Right Badge: 🟢 On-Device AI • Apple Silicon Neural Engine
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.greenLocal)
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.greenLocal.opacity(0.6), radius: 3)

                Text("On-Device AI • Apple Silicon Neural Engine")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.trailing, 16)
        }
    }

    // MARK: - Sidebar

    private var sidebarPane: some View {
        VStack(spacing: 12) {
            if !coordinator.isRecording {
                // New Recording Button (displayed when NOT recording)
                Button {
                    selectedMeetingID = nil
                    Task { await coordinator.startMeeting() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New Recording")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("⌥N")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(
                        LinearGradient(
                            colors: [Theme.primaryBlue, Color(red: 0.16, green: 0.38, blue: 0.88)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.primaryBlue.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.option])
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                // Live "CURRENT MEETING" Card (displayed ONLY when recording starts)
                currentMeetingCard
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // PREVIOUS MEETINGS Header & Search
            VStack(spacing: 8) {
                HStack {
                    Text("PREVIOUS MEETINGS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    let isFiltering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Text(isFiltering ? "\(filteredPreviousMeetings.count) found" : "\(store.meetings.count) recorded")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isFiltering ? Theme.cyanWave : .white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isFiltering ? Theme.cyanWave.opacity(0.12) : Color.white.opacity(0.06), in: Capsule())
                }
                .padding(.horizontal, 12)

                // Search Field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(isSearchFocused ? Theme.cyanWave : .white.opacity(0.4))
                    TextField("Filter meetings...", text: $searchText)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .focused($isSearchFocused)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSearchFocused ? Theme.borderActive.opacity(0.8) : Theme.borderSubtle, lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }

            // Scrollable List of Previous Meeting Cards
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if filteredPreviousMeetings.isEmpty {
                        VStack(spacing: 8) {
                            Text(store.meetings.isEmpty ? "No meetings yet" : "No matches found")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button("Clear filter") {
                                    searchText = ""
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.primaryBlue)
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 24)
                    } else {
                        ForEach(filteredPreviousMeetings) { meeting in
                            MeetingCardView(
                                meeting: meeting,
                                isSelected: selectedMeetingID == meeting.id,
                                onSelect: {
                                    selectedMeetingID = meeting.id
                                    selectedSpeakerFilter = nil
                                },
                                onDelete: {
                                    if selectedMeetingID == meeting.id {
                                        selectedMeetingID = store.meetings.first(where: { $0.id != meeting.id })?.id
                                    }
                                    store.delete(meeting)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            // Sidebar Footer: 🔒 100% Local AI (Voz & Who)   v2.4
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.greenLocal)
                Text("100% Local Voz & Who")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text("v2.4")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bgApp)
            .overlay(alignment: .top) {
                Divider().background(Theme.borderSubtle)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.isRecording)
    }

    // MARK: - Current Meeting Card

    private var currentMeetingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row
            HStack(spacing: 6) {
                Circle()
                    .fill(coordinator.isRecording ? (coordinator.isPaused ? Color.orange : Theme.redRecording) : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .shadow(color: coordinator.isRecording ? Theme.redRecording.opacity(0.6) : .clear, radius: 3)

                Text("CURRENT MEETING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 0.95))

                Spacer()

                Text(coordinator.isRecording ? (coordinator.isPaused ? "Paused" : "Recording") : "Idle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(coordinator.isRecording ? Theme.redRecording : .white.opacity(0.4))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        coordinator.isRecording ? Theme.redRecording.opacity(0.18) : Color.white.opacity(0.06),
                        in: Capsule()
                    )
            }

            // Controls & Timer row
            HStack(spacing: 10) {
                // Animated Equalizer Waveform Bars
                EqualizerWaveformView(isActive: coordinator.isRecording && !coordinator.isPaused)

                // Timer
                Text(formatDuration(coordinator.recordingDuration))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                Spacer()

                // Pause / Resume button
                Button {
                    coordinator.togglePause()
                } label: {
                    Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(coordinator.isRecording ? 0.9 : 0.3))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.isRecording)

                // Stop button
                Button {
                    Task { await coordinator.stopMeeting(customTitle: liveMeetingTitle) }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(coordinator.isRecording ? Theme.redRecording : .white.opacity(0.3))
                        .frame(width: 26, height: 26)
                        .background(
                            coordinator.isRecording ? Theme.redRecording.opacity(0.2) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.option])
                .disabled(!coordinator.isRecording)
            }
        }
        .padding(12)
        .background(
            selectedMeetingID == nil
                ? Theme.bgCardActive
                : Theme.bgCard,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    selectedMeetingID == nil ? Theme.borderActive.opacity(0.5) : Theme.borderSubtle,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMeetingID = nil
            selectedSpeakerFilter = nil
        }
    }

    // MARK: - Center Column: Transcript

    private var transcriptPane: some View {
        let segments = selectedMeeting?.transcript ?? coordinator.liveTranscript
        let uniqueSpeakers = getUniqueSpeakers(from: segments)

        let visibleSegments = segments.filter { seg in
            if let filter = selectedSpeakerFilter {
                return seg.speaker == filter
            }
            return true
        }

        return VStack(spacing: 0) {
            // Meeting Title Header with edit button
            HStack(spacing: 8) {
                Text(currentTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Button {
                    newTitleText = currentTitle
                    isRenamingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isRenamingTitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Rename Meeting")
                            .font(.system(size: 13, weight: .bold))
                        TextField("Meeting Title", text: $newTitleText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                        HStack {
                            Button("Cancel") { isRenamingTitle = false }
                            Spacer()
                            Button("Save") {
                                if let meeting = selectedMeeting {
                                    store.renameTitle(in: meeting.id, to: newTitleText)
                                } else {
                                    liveMeetingTitle = newTitleText
                                }
                                isRenamingTitle = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newTitleText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Speaker Filter Pill Bar
            if !segments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // "All" filter pill
                        FilterPill(
                            title: "All",
                            count: segments.count,
                            dotColor: nil,
                            isSelected: selectedSpeakerFilter == nil
                        ) {
                            selectedSpeakerFilter = nil
                        }

                        // Each speaker filter pill
                        ForEach(uniqueSpeakers, id: \.self) { speaker in
                            let count = segments.filter { $0.speaker == speaker }.count
                            FilterPill(
                                title: speaker,
                                count: count,
                                dotColor: speakerDotColor(for: speaker),
                                isSelected: selectedSpeakerFilter == speaker
                            ) {
                                selectedSpeakerFilter = speaker
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
            }

            // Transcript Messages ScrollView
            if segments.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    if coordinator.isRecording {
                        EqualizerWaveformView(isActive: !coordinator.isPaused)
                            .scaleEffect(1.3)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                    Text(coordinator.isRecording ? "Listening for speech…" : "No transcript yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(coordinator.isRecording ? "Speak into your microphone or play meeting audio. Text appears in real time." : "Click New Recording to capture a live conversation.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(visibleSegments) { segment in
                                TranscriptBubble(
                                    segment: segment,
                                    isYou: segment.speaker == "You" || segment.channel == .mic,
                                    onRename: { newName in
                                        if let meeting = selectedMeeting {
                                            store.renameSpeaker(in: meeting.id, from: segment.speaker, to: newName)
                                        } else {
                                            coordinator.renameLiveSpeaker(from: segment.speaker, to: newName)
                                        }
                                    }
                                )
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: segments.count) {
                        if isLive, let last = visibleSegments.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Right Column: AI Insights

    private var insightsPane: some View {
        let notes = selectedMeeting?.notes ?? coordinator.currentNotes

        return VStack(spacing: 0) {
            // Header: 🔵 AI Meeting Insights   Copy  Notes
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.primaryBlue)
                    .frame(width: 8, height: 8)
                Text("AI Meeting Insights")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    copySummary(notes)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedAlert ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copiedAlert ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)

                Button {
                    copyFullNotes(notes)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.yellow)
                        Text("Notes")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Insights Content
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    executiveSummaryCard(notes: notes)
                    actionItemsCard(notes: notes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }

            Spacer(minLength: 0)

            // Footer: 🟢 Generated locally • 0ms network latency   Synced
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.greenLocal)
                    .frame(width: 6, height: 6)
                Text("Generated locally • 0ms network latency")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("Synced")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.greenLocal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.greenLocal.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.bgApp)
            .overlay(alignment: .top) {
                Divider().background(Theme.borderSubtle)
            }
        }
    }

    // MARK: - Executive Summary Card

    private func executiveSummaryCard(notes: MeetingNotes?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("EXECUTIVE SUMMARY")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                Text("Qwen 2.5 • 3B")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }

            if let summary = notes?.summary, !summary.isEmpty {
                // Paragraph
                Text(summary)
                    .font(.system(size: 12.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)

                // Key bullet points if available
                if let decisions = notes?.keyDecisions, !decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(decisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Theme.cyanWave)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 6)
                                Text(decision)
                                    .font(.system(size: 12))
                                    .lineSpacing(3.5)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else if coordinator.isRecording {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.greenLocal)
                            .frame(width: 6, height: 6)
                        Text("Live synthesis active • Listening to conversation…")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.greenLocal)
                    }

                    Text("On-device AI will automatically generate executive summary and key points as the meeting proceeds.")
                        .font(.system(size: 11.5))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 4)
            } else {
                Text("Select a meeting from the sidebar or record a new one to generate AI insights.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Action Items Card

    private func actionItemsCard(notes: MeetingNotes?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.greenLocal)
                    Text("ACTION ITEMS & NEXT STEPS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()
            }

            if let items = notes?.actionItems, !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(Theme.greenLocal)
                                .frame(width: 4, height: 4)
                                .padding(.top, 6)
                            Text(item.task)
                                .font(.system(size: 12))
                                .lineSpacing(3.5)
                                .foregroundStyle(.white.opacity(0.85))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            } else if coordinator.isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primaryBlue)
                    Text("Detecting tasks, commitments & next steps…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.vertical, 4)
            } else {
                Text("No action items detected.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func getUniqueSpeakers(from segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for s in segments {
            if seen.insert(s.speaker).inserted {
                list.append(s.speaker)
            }
        }
        return list
    }

    private func speakerDotColor(for speaker: String) -> Color {
        if speaker == "You" { return Theme.primaryBlue }
        if speaker.contains("1") || speaker.contains("Alex") { return Theme.greenLocal }
        if speaker.contains("2") || speaker.contains("Emily") { return Theme.purpleSpeaker }
        let palette: [Color] = [Theme.greenLocal, Theme.purpleSpeaker, Theme.cyanWave, Color.orange, Color.pink]
        let hash = speaker.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[hash % palette.count]
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func copySummary(_ notes: MeetingNotes?) {
        guard let notes = notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notes.summary, forType: .string)
        withAnimation { copiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedAlert = false }
        }
    }

    private func copyFullNotes(_ notes: MeetingNotes?) {
        guard let notes = notes else { return }
        var md = "# Meeting Notes\n\n## Executive Summary\n\(notes.summary)\n\n"
        if !notes.keyDecisions.isEmpty {
            md += "## Key Decisions\n"
            for d in notes.keyDecisions {
                md += "- \(d)\n"
            }
            md += "\n"
        }
        if !notes.actionItems.isEmpty {
            md += "## Action Items & Next Steps\n"
            for item in notes.actionItems {
                md += "- \(item.task)\n"
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        withAnimation { copiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedAlert = false }
        }
    }
}

// MARK: - Equalizer Waveform View

struct EqualizerWaveformView: View {
    let isActive: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            bar(height: isActive ? 10 + 6 * sin(phase + 0) : 6)
            bar(height: isActive ? 16 + 8 * sin(phase + 1.2) : 10)
            bar(height: isActive ? 22 + 8 * sin(phase + 2.4) : 14)
            bar(height: isActive ? 14 + 6 * sin(phase + 3.6) : 8)
        }
        .frame(height: 22, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.cyanWave)
            .frame(width: 3.5, height: max(4, height))
    }
}

// MARK: - Previous Meeting Card

struct MeetingCardView: View {
    let meeting: Meeting
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date + Duration pill + Trash button
            HStack {
                Text(meeting.date.formatted(.dateTime.day().month(.abbreviated).year()) + " at " + meeting.date.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))

                Spacer()

                Text("\(meeting.durationMinutes)m")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.cyanWave)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Theme.cyanWave.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(isHovering ? 0.6 : 0.25))
                }
                .buttonStyle(.plain)
            }

            // Title
            Text(meeting.displayTitle)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            // Snippet
            Text(meeting.notes?.summary ?? (meeting.transcript.first?.text ?? "No transcript"))
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)

            // Speaker Badges row: [A] [E] [Y] 3 speakers
            HStack(spacing: 5) {
                HStack(spacing: -4) {
                    ForEach(meeting.uniqueSpeakers.prefix(3), id: \.self) { speaker in
                        avatarCircle(for: speaker)
                    }
                }

                Text("\(meeting.uniqueSpeakers.count) speakers")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 2)
            }
            .padding(.top, 2)
        }
        .padding(11)
        .background(
            isSelected ? Theme.bgCardActive : Theme.bgCard,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? Theme.borderActive.opacity(0.7) : Theme.borderSubtle,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private func avatarCircle(for speaker: String) -> some View {
        let initial = String(speaker.components(separatedBy: "•").last?.trimmingCharacters(in: .whitespaces).prefix(1) ?? speaker.prefix(1)).uppercased()
        let bg = speakerColor(for: speaker)
        return Text(initial)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(bg, in: Circle())
            .overlay(Circle().stroke(Theme.bgSidebar, lineWidth: 1.5))
    }

    private func speakerColor(for speaker: String) -> Color {
        if speaker == "You" { return Theme.primaryBlue }
        if speaker.contains("1") || speaker.contains("Alex") { return Theme.greenLocal }
        if speaker.contains("2") || speaker.contains("Emily") { return Theme.purpleSpeaker }
        return Theme.cyanWave
    }
}

// MARK: - Filter Pill

struct FilterPill: View {
    let title: String
    let count: Int
    let dotColor: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dotColor = dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }

                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .white.opacity(0.4))
            }
            .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Theme.primaryBlue : Color.white.opacity(0.06),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Theme.primaryBlue : Theme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transcript Bubble

struct TranscriptBubble: View {
    let segment: TranscriptSegment
    let isYou: Bool
    let onRename: (String) -> Void

    @State private var isRenaming = false
    @State private var newSpeakerName = ""

    private var dotColor: Color {
        if segment.speaker == "You" { return Theme.primaryBlue }
        if segment.speaker.contains("1") || segment.speaker.contains("Alex") { return Theme.greenLocal }
        if segment.speaker.contains("2") || segment.speaker.contains("Emily") { return Theme.purpleSpeaker }
        return Theme.cyanWave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: Speaker badge + Timestamp
            HStack(spacing: 8) {
                // Speaker badge with pencil
                Button {
                    newSpeakerName = segment.speaker
                    isRenaming = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)

                        Text(segment.speaker)
                            .font(.system(size: 11.5, weight: .semibold))

                        Image(systemName: "pencil")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .foregroundStyle(dotColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(dotColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isRenaming) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Rename Speaker")
                            .font(.system(size: 13, weight: .bold))
                        TextField("e.g. Alex", text: $newSpeakerName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        HStack {
                            Button("Cancel") { isRenaming = false }
                            Spacer()
                            Button("Save") {
                                let trimmed = newSpeakerName.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    onRename(trimmed)
                                }
                                isRenaming = false
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newSpeakerName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                }

                // Timestamp
                Text(formatTimestamp(segment.start))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                Spacer()
            }

            // Message text
            Text(segment.text.cleanedTranscript)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(isYou ? 12 : 6)
        .background(
            isYou
                ? Theme.bgCard.opacity(0.7)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            isYou
                ? RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle, lineWidth: 1)
                : nil
        )
    }

    private func formatTimestamp(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Key Window & Activation Enforcer

struct KeyWindowEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        EnforcingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class EnforcingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if let window, !window.isKeyWindow {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            return super.hitTest(point)
        }
    }
}

