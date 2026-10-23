import SwiftUI
import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = MeetingCoordinator()

    var body: some Scene {
        MenuBarExtra("MeetingNotes", systemImage: coordinator.isRecording ? "record.circle.fill" : "waveform") {
            MenuBarView()
                .environmentObject(coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Meeting Notes", id: "main") {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Recording") {
                // A menu key equivalent works whenever the app is active, unlike a
                // view-level .keyboardShortcut that needs its window to be key.
                Button(coordinator.isRecording ? "Stop & Summarize" : "Start Recording") {
                    Task {
                        if coordinator.isRecording {
                            await coordinator.stopMeeting()
                        } else {
                            await coordinator.startMeeting()
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: [.option])

                Button(coordinator.isPaused ? "Resume" : "Pause") { coordinator.togglePause() }
                    .disabled(!coordinator.isRecording)
            }
        }
    }
}

/// Orchestrates the whole pipeline:
/// capture → transcribe (live) → diarize (post) → summarize (post).
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var liveTranscript: [TranscriptSegment] = []
    @Published var currentNotes: MeetingNotes?
    @Published var status: String = "Idle"
    @Published var lastSavedMeetingID: UUID?
    /// Title typed for the meeting in progress; empty = derive one from the summary.
    @Published var liveTitle = ""

    let store = MeetingStore()
    private var meetingStart: Date?
    private var timerTask: Task<Void, Never>?

    private let mic = MicCapture()
    private let systemTap = SystemAudioTap()
    private let transcriber = TranscriptionService()
    private let diarizer = DiarizationService()
    private let summarizer = SummarizationService()
    private let vad = VoiceActivityDetector()

    // Raw 16 kHz mono buffers kept for post-meeting diarization.
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
    }

    func startMeeting() async {
        guard !isRecording else { return }

        // Ask for mic access before touching AVAudioEngine — with access not
        // yet granted the input node reports an invalid HW format and CoreAudio
        // faults instead of prompting.
        status = "Requesting microphone access…"
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            status = "Microphone access denied — enable it in System Settings → Privacy & Security → Microphone."
            return
        }

        status = "Loading speech recognition (Voz)…"
        do {
            try await transcriber.prepare()
            status = "Loading speaker diarization (Who)…"
            try await diarizer.prepare()
            status = "Recording"
            isRecording = true
            isPaused = false
            recordingDuration = 0
            meetingStart = Date()
            micSamples.removeAll(); systemSamples.removeAll()
            liveTranscript.removeAll(); currentNotes = nil
            liveTitle = ""
            vad.reset()

            liveSummaryTask?.cancel()
            liveSummaryTask = nil
            lastLiveSummarizedCount = 0
            lastLiveSummaryAt = .distantPast
            timerTask?.cancel()
            timerTask = Task { @MainActor [weak self] in
                while let self = self, self.isRecording {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !self.isPaused {
                        self.recordingDuration += 1
                    }
                }
            }

            transcriber.start { [weak self] segment in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.liveTranscript.append(segment)
                    self.triggerLiveSummarization()
                }
            }

            // Two channels: mic = "You", system tap = "Them".
            try mic.start { [weak self] samples in
                Task { @MainActor in self?.ingest(samples, channel: .mic) }
            }
            try systemTap.start { [weak self] samples in
                Task { @MainActor in self?.ingest(samples, channel: .system) }
            }

            // Pre-warm the local LLM in the background so it's instant when stopping
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await self?.summarizer.prepare()
            }
        } catch {
            print("MeetingCoordinator start error: \(error)")
            status = "Failed to start: \(error.localizedDescription)"
            isRecording = false
            timerTask?.cancel()
            timerTask = nil
            // The mic may already be running if the system tap failed.
            mic.stop(); systemTap.stop()
            _ = await transcriber.finish()
        }
    }

    private var liveSummaryTask: Task<Void, Never>?
    private var lastLiveSummarizedCount = 0
    private var lastLiveSummaryAt = Date.distantPast
    /// Live summaries rerun the LLM over the whole transcript, so keep them sparse.
    private let liveSummaryMinInterval: TimeInterval = 45
    private let liveSummaryMinNewSegments = 4

    private func ingest(_ samples: [Float], channel: AudioChannel) {
        guard !isPaused else { return }
        switch channel {
        case .mic:
            micSamples.append(contentsOf: samples)
            // Mic frames that are only speaker bleed-through are replaced with
            // silence (not dropped) so the mic timeline stays aligned.
            let speaking = vad.isUserSpeaking(micSamples: samples)
            transcriber.feed(speaking ? samples : [Float](repeating: 0, count: samples.count), channel: .mic)
        case .system:
            systemSamples.append(contentsOf: samples)
            vad.feedSystem(samples)
            transcriber.feed(samples, channel: .system)
        }
    }

    private func triggerLiveSummarization() {
        guard isRecording, liveSummaryTask == nil else { return }
        let count = liveTranscript.count
        guard count - lastLiveSummarizedCount >= liveSummaryMinNewSegments,
              Date().timeIntervalSince(lastLiveSummaryAt) >= liveSummaryMinInterval else { return }
        lastLiveSummaryAt = Date()
        let snapshot = liveTranscript

        liveSummaryTask = Task { [weak self, summarizer] in
            let notes = try? await summarizer.summarize(transcript: snapshot)
            guard let self else { return }
            self.liveSummaryTask = nil
            // A result arriving after Stop is stale — the final summary owns currentNotes.
            guard !Task.isCancelled, self.isRecording, let notes else { return }
            self.currentNotes = notes
            self.lastLiveSummarizedCount = count
        }
    }

    func stopMeeting(customTitle: String? = nil) async {
        guard isRecording else { return }
        timerTask?.cancel()
        timerTask = nil
        mic.stop(); systemTap.stop()
        isRecording = false
        isPaused = false
        liveSummaryTask?.cancel()
        liveSummaryTask = nil

        status = "Finalizing transcript…"
        let finalSegments = await transcriber.finish()
        liveTranscript = TranscriptDeduplicator.deduplicate(finalSegments.sorted { $0.start < $1.start })

        status = "Identifying speakers (Who)…"
        let diarized = await diarizer.diarize(
            micSamples: micSamples,
            systemSamples: systemSamples,
            segments: liveTranscript
        )
        liveTranscript = diarized

        status = "Summarizing on-device…"
        do {
            currentNotes = try await summarizer.summarize(transcript: diarized)
            status = "Done"
        } catch {
            status = "Summarization failed: \(error.localizedDescription)"
        }

        // Persist the meeting even if summarization failed — the transcript is
        // still useful. Once saved, the store owns it: clear the live state and
        // let the UI switch to the saved copy.
        if !liveTranscript.isEmpty {
            var meeting = Meeting(date: meetingStart ?? Date(), transcript: liveTranscript, notes: currentNotes)
            let title = (customTitle ?? liveTitle).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                meeting.title = title
            }
            store.save(meeting)
            liveTranscript = []
            currentNotes = nil
            lastSavedMeetingID = meeting.id
        }
    }

    func renameLiveSpeaker(from oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        liveTranscript = liveTranscript.map { seg in
            if seg.speaker == oldName {
                var s = seg
                s.speaker = trimmed
                return s
            }
            return seg
        }
    }
}

enum AudioChannel: String, Codable { case mic, system }
