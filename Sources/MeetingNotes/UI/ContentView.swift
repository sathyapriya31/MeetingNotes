import SwiftUI
import AppKit

// MARK: - Design System & Theme

enum Theme {
    // Each colour resolves against the current appearance (see AppAppearance),
    // so views pick up Light/Dark changes without being rebuilt.
    static let bgApp = dynamic(dark: (0.05, 0.07, 0.09), light: (0.965, 0.972, 0.980))        // #0D1117 / #F6F8FA
    static let bgSidebar = dynamic(dark: (0.07, 0.09, 0.12), light: (0.933, 0.945, 0.961))    // #121620 / #EEF1F5
    static let bgSurface = dynamic(dark: (0.09, 0.12, 0.16), light: (1.0, 1.0, 1.0))          // #171D27 / #FFFFFF
    static let bgCard = dynamic(dark: (0.10, 0.13, 0.18), light: (1.0, 1.0, 1.0))             // #1A202C / #FFFFFF
    static let bgCardActive = dynamic(dark: (0.12, 0.17, 0.25), light: (0.906, 0.933, 0.984)) // #1F2C40 / #E7EEFB
    /// Primary text/icon colour; use `.opacity()` for secondary tints.
    static let fg = dynamic(dark: (1.0, 1.0, 1.0), light: (0.07, 0.09, 0.13))                 // #FFFFFF / #12171F
    static let borderSubtle = fg.opacity(0.08)
    static let borderActive = Color(red: 0.25, green: 0.50, blue: 0.95)

    static let primaryBlue = Color(red: 0.22, green: 0.48, blue: 0.96)                        // #387BF6
    static let cyanWave = dynamic(dark: (0.15, 0.75, 0.90), light: (0.03, 0.53, 0.70))        // #26BFE6 / #0887B3
    static let greenLocal = dynamic(dark: (0.18, 0.75, 0.48), light: (0.09, 0.58, 0.34))      // #2EBF7A / #179457
    static let purpleSpeaker = Color(red: 0.68, green: 0.38, blue: 0.88)                      // #AE61E0
    static let redRecording = Color(red: 0.94, green: 0.28, blue: 0.33)                       // #F04754

    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// User-selectable appearance, persisted under `appearanceKey`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let appearanceKey = "appAppearance"
    static let defaultValue = AppAppearance.dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Applied app-wide so every window, popover, alert and the menu-bar panel
    /// follow the choice (`nil` = follow macOS).
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Segmented Light / Dark / System picker bound to the stored appearance.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.appearanceKey) private var appearance = AppAppearance.defaultValue

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { option in
                Label(option.title, systemImage: option.symbol).tag(option)
            }
        }
        .onChange(of: appearance) { appearance.apply() }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            AppearancePicker()
                .pickerStyle(.segmented)
            Text("System follows the macOS appearance setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}

// MARK: - MenuBar View

struct MenuBarView: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if coordinator.isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(coordinator.isRecording ? Theme.redRecording : .secondary)
                        .frame(width: 8, height: 8)
                }
                Text(coordinator.status)
                    .font(.system(size: 13, weight: .medium))
            }
            if coordinator.isRecording {
                Button("Stop & Summarize") { Task { await coordinator.stopMeeting() } }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button("Start Meeting Capture") { Task { await coordinator.startMeeting() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(coordinator.isPreparing)
            }
            Button("Open Meeting Notes") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: [.command])
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
    @AppStorage(AppAppearance.appearanceKey) private var appearance = AppAppearance.defaultValue
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    /// Best EmbeddingGemma similarity per meeting for the current `searchText`.
    @State private var semanticScores: [UUID: Float] = [:]

    /// Minimum cosine similarity for a meeting to show up as a "by meaning" match.
    /// Raise it if unrelated meetings appear; lower it if obvious matches are missed.
    private static let semanticThreshold: Float = 0.45
    private static let maxSemanticResults = 10
    @State private var selectedSpeakerFilter: String? = nil
    @State private var isRenamingTitle = false
    @State private var newTitleText = ""
    @State private var copiedAlert = false
    @State private var showClearAllAlert = false
    @State private var insightsTab: InsightsTab = .insights
    @State private var askMessages: [AskMessage] = []
    @State private var folderFilter: FolderFilter = .all
    @State private var folderPrompt: FolderPrompt? = nil
    @State private var folderNameText = ""
    @State private var folderToDelete: String? = nil
    @State private var isEditingSummary = false
    @State private var summaryDraft = ""
    @State private var decisionsDraft = ""

    private enum InsightsTab { case insights, ask }

    private enum FolderFilter: Hashable {
        case all, unfiled
        case named(String)
    }

    /// The "name a folder" alert: create (optionally filing a meeting into it) or rename.
    private enum FolderPrompt {
        case create(fileMeeting: UUID?)
        case rename(String)
    }

    /// Meetings in the selected folder; search runs within these.
    private var scopedMeetings: [Meeting] {
        store.meetings.filter { meeting in
            switch folderFilter {
            case .all: return true
            case .unfiled: return meeting.folder == nil
            case .named(let name): return meeting.folder == name
            }
        }
    }

    private var isScoped: Bool {
        folderFilter != .all
    }

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
        return coordinator.liveTitle.isEmpty ? "Untitled Meeting" : coordinator.liveTitle
    }

    /// Keyword matches first (newest first), then meetings that match by meaning
    /// (EmbeddingGemma), best match first.
    private var filteredPreviousMeetings: [Meeting] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return scopedMeetings
        }
        let keywordMatches = keywordFilteredMeetings(trimmed.lowercased())
        return keywordMatches + semanticOnlyMatches(excluding: Set(keywordMatches.map(\.id)))
    }

    private func semanticOnlyMatches(excluding ids: Set<UUID>) -> [Meeting] {
        let scored = scopedMeetings.compactMap { meeting -> (Meeting, Float)? in
            guard !ids.contains(meeting.id),
                  let score = semanticScores[meeting.id],
                  score >= Self.semanticThreshold else { return nil }
            return (meeting, score)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxSemanticResults)
            .map(\.0)
    }

    private var semanticMatchCount: Int {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let keywordIDs = Set(keywordFilteredMeetings(trimmed.lowercased()).map(\.id))
        return semanticOnlyMatches(excluding: keywordIDs).count
    }

    private func keywordFilteredMeetings(_ q: String) -> [Meeting] {
        scopedMeetings.filter { meeting in
            // 1. Title & Display Title
            if meeting.displayTitle.lowercased().contains(q) { return true }
            if let title = meeting.title, title.lowercased().contains(q) { return true }

            // 1b. Folder name
            if let folder = meeting.folder, folder.lowercased().contains(q) { return true }

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
                if (notes.enhancedNotes ?? []).contains(where: { $0.lowercased().contains(q) }) { return true }
            }
            if let userNotes = meeting.userNotes, userNotes.lowercased().contains(q) { return true }

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
        .background(KeyWindowEnforcer())
        .onAppear {
            if selectedMeetingID == nil, let first = store.meetings.first {
                selectedMeetingID = first.id
            }
        }
        .onChange(of: coordinator.isPreparing) {
            // Started from the menu bar / ⌥N: switch to the live view so the
            // loading state is visible.
            if coordinator.isPreparing {
                selectedMeetingID = nil
            }
        }
        .onChange(of: coordinator.isRecording) {
            if coordinator.isRecording {
                selectedMeetingID = nil
            }
        }
        .onChange(of: selectedMeetingID) {
            isEditingSummary = false
        }
        .onChange(of: coordinator.lastSavedMeetingID) {
            if let id = coordinator.lastSavedMeetingID {
                selectedMeetingID = id
            }
        }
        .alert("Clear All Meetings?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.deleteAll()
                selectedMeetingID = nil
            }
        } message: {
            Text("Are you sure you want to delete all recorded meetings? This action cannot be undone.")
        }
        .alert(folderPromptTitle, isPresented: Binding(
            get: { folderPrompt != nil },
            set: { if !$0 { folderPrompt = nil } }
        )) {
            TextField("Folder name", text: $folderNameText)
            Button("Cancel", role: .cancel) { folderPrompt = nil }
            Button(folderPromptIsRename ? "Rename" : "Create") { commitFolderPrompt() }
        }
        .alert("Delete Folder \"\(folderToDelete ?? "")\"?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { folderToDelete = nil }
            Button("Delete Folder", role: .destructive) {
                if let name = folderToDelete {
                    if folderFilter == .named(name) { folderFilter = .all }
                    store.deleteFolder(name)
                }
                folderToDelete = nil
            }
        } message: {
            Text("Meetings in this folder are kept and moved to Unfiled.")
        }
    }

    // MARK: - Folders

    private var folderPromptIsRename: Bool {
        if case .rename = folderPrompt { return true }
        return false
    }

    private var folderPromptTitle: String {
        folderPromptIsRename ? "Rename Folder" : "New Folder"
    }

    private func promptForFolder(_ prompt: FolderPrompt) {
        if case .rename(let name) = prompt {
            folderNameText = name
        } else {
            folderNameText = ""
        }
        folderPrompt = prompt
    }

    private func commitFolderPrompt() {
        let name = folderNameText.trimmingCharacters(in: .whitespaces)
        switch folderPrompt {
        case .create(let meetingID):
            if let meetingID {
                store.moveMeeting(meetingID, toFolder: name)
            } else {
                store.createFolder(name)
            }
        case .rename(let oldName):
            store.renameFolder(oldName, to: name)
            if folderFilter == .named(oldName), store.folders.contains(name) {
                folderFilter = .named(name)
            }
        case nil:
            break
        }
        folderPrompt = nil
    }

    /// "Move to Folder" menu items, shared by the meeting card's context menu and the detail header.
    @ViewBuilder
    private func folderMenuItems(for meeting: Meeting) -> some View {
        Button {
            store.moveMeeting(meeting.id, toFolder: nil)
        } label: {
            Label("Unfiled", systemImage: meeting.folder == nil ? "checkmark" : "tray")
        }
        if !store.folders.isEmpty {
            Divider()
            ForEach(store.folders, id: \.self) { folder in
                Button {
                    store.moveMeeting(meeting.id, toFolder: folder)
                } label: {
                    Label(folder, systemImage: meeting.folder == folder ? "checkmark" : "folder")
                }
            }
        }
        Divider()
        Button("New Folder…") { promptForFolder(.create(fileMeeting: meeting.id)) }
    }

    /// Sidebar folder filter row.
    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterPill(title: "All", count: store.meetings.count, dotColor: nil,
                           isSelected: folderFilter == .all) {
                    folderFilter = .all
                }
                let unfiled = store.meetings.filter { $0.folder == nil }.count
                if !store.folders.isEmpty && unfiled > 0 {
                    FilterPill(title: "Unfiled", count: unfiled, dotColor: nil,
                               isSelected: folderFilter == .unfiled) {
                        folderFilter = .unfiled
                    }
                }
                ForEach(store.folders, id: \.self) { folder in
                    FilterPill(
                        title: folder,
                        count: store.meetings.filter { $0.folder == folder }.count,
                        dotColor: nil,
                        systemImage: "folder.fill",
                        isSelected: folderFilter == .named(folder)
                    ) {
                        folderFilter = .named(folder)
                    }
                    .contextMenu {
                        Button("Rename…") { promptForFolder(.rename(folder)) }
                        Button("Delete Folder…", role: .destructive) { folderToDelete = folder }
                    }
                }
                Button {
                    promptForFolder(.create(fileMeeting: nil))
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.fg.opacity(0.6))
                        .frame(width: 26, height: 22)
                        .background(Theme.fg.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("New folder (right-click a folder to rename or delete it)")
            }
            .padding(.horizontal, 12)
        }
    }

    /// Folder menu under the meeting title (saved meetings only).
    private func meetingFolderRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 6) {
            Menu {
                folderMenuItems(for: meeting)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: meeting.folder == nil ? "tray" : "folder.fill")
                    Text(meeting.folder ?? "Unfiled")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Theme.fg.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Theme.borderSubtle, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to folder")

            Spacer()
        }
        .padding(.horizontal, 24)
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
                    .foregroundStyle(Theme.fg)

                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fg.opacity(0.3))

                Text(Date().formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.fg.opacity(0.6))
            }

            Spacer()

            // Appearance switcher (also in Settings, ⌘,)
            Menu {
                AppearancePicker()
                    .pickerStyle(.inline)
            } label: {
                Image(systemName: appearance.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg.opacity(0.75))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Appearance: \(appearance.title)")
            .padding(.trailing, 10)

            // Right Badge: 🟢 On-Device AI • Apple Silicon Neural Engine
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.greenLocal)
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.greenLocal.opacity(0.6), radius: 3)

                Text("On-Device AI • Apple Silicon Neural Engine")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.fg.opacity(0.9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Theme.fg.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .stroke(Theme.fg.opacity(0.12), lineWidth: 1)
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
                        if coordinator.isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .colorScheme(.dark)   // light spinner on the blue button
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(coordinator.isPreparing ? "Preparing…" : "New Recording")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
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
                    .opacity(coordinator.isPreparing ? 0.8 : 1)
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isPreparing)
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
                HStack(spacing: 8) {
                    Text("PREVIOUS MEETINGS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.fg.opacity(0.45))
                    Spacer()
                    if !store.meetings.isEmpty {
                        Button("Clear All") {
                            showClearAllAlert = true
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.75))
                        .buttonStyle(.plain)
                    }
                    let isFiltering = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let byMeaning = semanticMatchCount
                    Text(isFiltering
                         ? "\(filteredPreviousMeetings.count) found" + (byMeaning > 0 ? " · \(byMeaning) by meaning" : "")
                         : isScoped ? "\(scopedMeetings.count) shown" : "\(store.meetings.count) recorded")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isFiltering ? Theme.cyanWave : Theme.fg.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isFiltering ? Theme.cyanWave.opacity(0.12) : Theme.fg.opacity(0.06), in: Capsule())
                }
                .padding(.horizontal, 12)

                // Search Field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(isSearchFocused ? Theme.cyanWave : Theme.fg.opacity(0.4))
                    TextField("Search meetings or describe a topic…", text: $searchText)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.fg)
                        .focused($isSearchFocused)
                        .task(id: searchText) {
                            semanticScores = [:]
                            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Very short queries are left to keyword search.
                            guard query.count >= 3 else { return }
                            // Debounce: the task is cancelled if the user keeps typing.
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            let scores = (try? await store.semanticSearch.scores(for: query)) ?? [:]
                            guard !Task.isCancelled else { return }
                            semanticScores = scores
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.fg.opacity(0.4))
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

                folderBar
            }

            // Scrollable List of Previous Meeting Cards
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    if filteredPreviousMeetings.isEmpty {
                        VStack(spacing: 8) {
                            let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            Text(store.meetings.isEmpty ? "No meetings yet"
                                 : isSearching ? "No matches found" : "No meetings here yet")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.fg.opacity(0.4))
                            if isSearching || isScoped {
                                Button("Clear filter") {
                                    searchText = ""
                                    folderFilter = .all
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
                            .contextMenu {
                                Menu("Move to Folder") {
                                    folderMenuItems(for: meeting)
                                }
                            }
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
                    .foregroundStyle(Theme.fg.opacity(0.75))
                Spacer()
                Text("v2.4")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.fg.opacity(0.45))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.fg.opacity(0.06), in: Capsule())
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
                    .fill(coordinator.isRecording ? (coordinator.isPaused ? Color.orange : Theme.redRecording) : Theme.fg.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .shadow(color: coordinator.isRecording ? Theme.redRecording.opacity(0.6) : .clear, radius: 3)

                Text("CURRENT MEETING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 0.95))

                Spacer()

                Text(coordinator.isRecording ? (coordinator.isPaused ? "Paused" : "Recording") : "Idle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(coordinator.isRecording ? Theme.redRecording : Theme.fg.opacity(0.4))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        coordinator.isRecording ? Theme.redRecording.opacity(0.18) : Theme.fg.opacity(0.06),
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
                    .foregroundStyle(Theme.fg)

                Spacer()

                // Pause / Resume button
                Button {
                    coordinator.togglePause()
                } label: {
                    Image(systemName: coordinator.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.fg.opacity(coordinator.isRecording ? 0.9 : 0.3))
                        .frame(width: 26, height: 26)
                        .background(Theme.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.isRecording)

                // Stop button
                Button {
                    Task { await coordinator.stopMeeting() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(coordinator.isRecording ? Theme.redRecording : Theme.fg.opacity(0.3))
                        .frame(width: 26, height: 26)
                        .background(
                            coordinator.isRecording ? Theme.redRecording.opacity(0.2) : Theme.fg.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
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
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)

                Button {
                    newTitleText = selectedMeeting == nil ? coordinator.liveTitle : currentTitle
                    isRenamingTitle = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg.opacity(0.5))
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
                                    coordinator.liveTitle = newTitleText
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
            .padding(.bottom, selectedMeeting == nil ? 12 : 6)

            if let meeting = selectedMeeting {
                meetingFolderRow(meeting)
                    .padding(.bottom, 10)
            }

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
            if segments.isEmpty && coordinator.isPreparing {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text(coordinator.status)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg.opacity(0.75))
                    Text("Loading the on-device models. The first recording after launch can take up to a minute — capture starts automatically when they're ready.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg.opacity(0.35))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty, !coordinator.isRecording, selectedMeetingID == nil, let error = coordinator.startError {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.orange)
                    Text("Couldn't start recording")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg.opacity(0.75))
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    if coordinator.isRecording {
                        EqualizerWaveformView(isActive: !coordinator.isPaused)
                            .scaleEffect(1.3)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.fg.opacity(0.2))
                    }
                    Text(coordinator.isRecording ? "Listening for speech…" : "No transcript yet")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.fg.opacity(0.75))
                    Text(coordinator.isRecording ? "Speak into your microphone or play meeting audio. Text appears in real time." : "Click New Recording to capture a live conversation.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fg.opacity(0.35))
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
                    .foregroundStyle(Theme.fg)

                Spacer()

                if insightsTab == .insights {
                    Button {
                        copySummary(notes)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copiedAlert ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copiedAlert ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.fg.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)

                    Button {
                        copyFullNotes(notes, userNotes: selectedMeeting?.userNotes ?? coordinator.liveUserNotes)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "note.text")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.yellow)
                            Text("Notes")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.fg.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Tabs: Insights for the selected meeting | Ask across all meetings
            HStack(spacing: 6) {
                insightsTabButton("This Meeting", systemImage: "doc.text", tab: .insights)
                insightsTabButton("Ask", systemImage: "sparkles", tab: .ask)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            switch insightsTab {
            case .insights:
                // Insights Content
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        MyNotesCard(meeting: selectedMeeting)
                            .id(selectedMeetingID)   // fresh draft per meeting
                        if let enhanced = notes?.enhancedNotes, !enhanced.isEmpty {
                            enhancedNotesCard(enhanced)
                        }
                        executiveSummaryCard(notes: notes)
                        actionItemsCard(notes: notes)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }

                Spacer(minLength: 0)
            case .ask:
                AskMeetingsView(messages: $askMessages) { meetingID in
                    selectedMeetingID = meetingID
                    selectedSpeakerFilter = nil
                }
            }

            // Footer: 🟢 Generated locally • 0ms network latency   Synced
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.greenLocal)
                    .frame(width: 6, height: 6)
                Text("Generated locally • 0ms network latency")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Theme.fg.opacity(0.5))
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

    private func insightsTabButton(_ title: String, systemImage: String, tab: InsightsTab) -> some View {
        let isActive = insightsTab == tab
        return Button {
            insightsTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isActive ? Theme.fg : Theme.fg.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isActive ? Theme.primaryBlue.opacity(0.25) : Theme.fg.opacity(0.04),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? Theme.borderActive.opacity(0.6) : Theme.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Executive Summary Card

    private func executiveSummaryCard(notes: MeetingNotes?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.fg.opacity(0.7))
                    Text("EXECUTIVE SUMMARY")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.fg.opacity(0.85))
                }

                Spacer()

                if let meeting = selectedMeeting, !isEditingSummary {
                    Button {
                        summaryDraft = meeting.notes?.summary ?? ""
                        decisionsDraft = (meeting.notes?.keyDecisions ?? []).joined(separator: "\n")
                        isEditingSummary = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.fg.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Edit the summary and key decisions")
                } else if !isEditingSummary {
                    Text("Qwen 2.5 • 3B")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.fg.opacity(0.4))
                }
            }

            if isEditingSummary, let meeting = selectedMeeting {
                NotesTextEditor(text: $summaryDraft, placeholder: "Summary", height: 130)
                Text("Key decisions — one per line")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.fg.opacity(0.5))
                NotesTextEditor(text: $decisionsDraft, placeholder: "e.g. Ship v2 on Friday", height: 90)
                HStack {
                    Button("Cancel") { isEditingSummary = false }
                    Spacer()
                    Button("Save") {
                        store.updateSummary(in: meeting.id, summary: summaryDraft, decisions: decisionsDraft)
                        isEditingSummary = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else if let summary = notes?.summary, !summary.isEmpty {
                // Paragraph
                Text(summary)
                    .font(.system(size: 12.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(Theme.fg.opacity(0.85))
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
                                    .foregroundStyle(Theme.fg.opacity(0.8))
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
                        .foregroundStyle(Theme.fg.opacity(0.5))
                }
                .padding(.vertical, 4)
            } else {
                Text("Select a meeting from the sidebar or record a new one to generate AI insights.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg.opacity(0.4))
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

    // MARK: - Enhanced Notes Card

    /// The user's own notes, rewritten by the LLM with details from the transcript.
    private func enhancedNotesCard(_ bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.yellow)
                Text("ENHANCED NOTES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.fg.opacity(0.85))
                Spacer()
                Text("From your notes")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.fg.opacity(0.4))
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(bullet)
                            .font(.system(size: 12))
                            .lineSpacing(3.5)
                            .foregroundStyle(Theme.fg.opacity(0.85))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                        .foregroundStyle(Theme.fg.opacity(0.85))
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
                                .foregroundStyle(Theme.fg.opacity(0.85))
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
                        .foregroundStyle(Theme.fg.opacity(0.5))
                }
                .padding(.vertical, 4)
            } else {
                Text("No action items detected.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.fg.opacity(0.4))
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

    private func copyFullNotes(_ notes: MeetingNotes?, userNotes: String) {
        guard let notes = notes else { return }
        var md = "# Meeting Notes\n\n"
        if let enhanced = notes.enhancedNotes, !enhanced.isEmpty {
            md += "## Notes\n" + enhanced.map { "- \($0)\n" }.joined() + "\n"
        }
        md += "## Executive Summary\n\(notes.summary)\n\n"
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
        let mine = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty {
            md += "\n## My Notes\n\(mine)\n"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        withAnimation { copiedAlert = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedAlert = false }
        }
    }
}

// MARK: - My Notes Card

/// The user's own notes. For the live meeting it edits `coordinator.liveUserNotes`
/// (they steer the summary on Stop); for a saved meeting it edits a draft that is
/// saved after a short pause, and offers "Improve with AI" to regenerate the notes.
struct MyNotesCard: View {
    @EnvironmentObject var coordinator: MeetingCoordinator
    @EnvironmentObject var store: MeetingStore

    /// `nil` = the live meeting.
    let meeting: Meeting?

    @State private var draft = ""

    private var isImproving: Bool {
        meeting != nil && coordinator.improvingMeetingID == meeting?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.yellow)
                    Text("MY NOTES")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.fg.opacity(0.85))
                }

                Spacer()

                if let meeting {
                    Button {
                        save()
                        Task { await coordinator.improveNotes(for: meeting.id) }
                    } label: {
                        HStack(spacing: 4) {
                            if isImproving {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10))
                            }
                            Text(isImproving ? "Improving…" : "Improve with AI")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.primaryBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.primaryBlue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isRecording || coordinator.improvingMeetingID != nil || meeting.transcript.isEmpty)
                    .help(coordinator.isRecording
                          ? "Available after the current recording stops"
                          : "Rewrite the summary, decisions, action items and enhanced notes using your notes")
                }
            }

            NotesTextEditor(
                text: meeting == nil ? $coordinator.liveUserNotes : $draft,
                placeholder: meeting == nil
                    ? "Jot down key points as the meeting goes — names, numbers, things to follow up…"
                    : "Add your own notes, then Improve with AI to fold them into the summary.",
                height: 120
            )

            if meeting == nil {
                Text(coordinator.isRecording
                     ? "When you stop, on-device AI expands these into Enhanced Notes using the transcript."
                     : "You can start typing before you press New Recording.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.fg.opacity(0.4))
            } else if let error = coordinator.improveError, coordinator.improvingMeetingID == nil {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.bgCard, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
        .onAppear {
            draft = meeting?.userNotes ?? ""
            coordinator.improveError = nil
        }
        .task(id: draft) {
            // Debounce: each save rewrites the meeting file and re-embeds it for search.
            guard meeting != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard let meeting else { return }
        store.updateUserNotes(in: meeting.id, to: draft)
    }
}

// MARK: - Notes Text Editor

/// Multi-line editor styled like the app's search field, with a placeholder.
struct NotesTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.fg.opacity(0.3))
                    .padding(.horizontal, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Theme.fg.opacity(0.9))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
        }
        .frame(height: height)
        .padding(8)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Theme.borderActive.opacity(0.8) : Theme.borderSubtle, lineWidth: 1)
        )
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
                    .foregroundStyle(Theme.fg.opacity(0.45))

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
                        .foregroundStyle(Theme.fg.opacity(isHovering ? 0.6 : 0.25))
                }
                .buttonStyle(.plain)
            }

            // Title
            Text(meeting.displayTitle)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Theme.fg)
                .lineLimit(1)

            // Snippet
            Text(meeting.notes?.summary ?? (meeting.transcript.first?.text ?? "No transcript"))
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(Theme.fg.opacity(0.45))
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
                    .foregroundStyle(Theme.fg.opacity(0.45))
                    .padding(.leading, 2)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                if let folder = meeting.folder {
                    Label(folder, systemImage: "folder.fill")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.fg.opacity(0.5))
                        .lineLimit(1)
                }
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
    var systemImage: String? = nil
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
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9.5))
                }

                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))

                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Theme.fg.opacity(0.4))
            }
            .foregroundStyle(isSelected ? Color.white : Theme.fg.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? Theme.primaryBlue : Theme.fg.opacity(0.06),
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
                            .foregroundStyle(Theme.fg.opacity(0.4))
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
                    .foregroundStyle(Theme.fg.opacity(0.35))

                Spacer()
            }

            // Message text
            Text(segment.text.cleanedTranscript)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundStyle(Theme.fg.opacity(0.9))
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

/// The app is an `LSUIElement` (menu-bar) app, whose windows can't take
/// keyboard focus — so text fields like search don't work. While the main
/// window is open, promote the app to a regular (Dock) app and make the window
/// key; when it closes, drop back to menu-bar-only.
struct KeyWindowEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        EnforcingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class EnforcingView: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            guard let window else { return }

            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

