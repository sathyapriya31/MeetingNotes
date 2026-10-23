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

    let store = MeetingStore()
    private var meetingStart: Date?
    private var timerTask: Task<Void, Never>?

    private let mic = MicCapture()
    private let systemTap = SystemAudioTap()
    private let transcriber = TranscriptionService()
    private let diarizer = DiarizationService()
    private let summarizer = SummarizationService()

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

            isSummarizingLive = false
            lastLiveSummarizedCount = 0
            timerTask?.cancel()
            timerTask = Task { @MainActor [weak self] in
                while let self = self, self.isRecording {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !self.isPaused {
                        self.recordingDuration += 1
                    }
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
        }
    }

    private var isSummarizingLive = false
    private var lastLiveSummarizedCount = 0

    private func ingest(_ samples: [Float], channel: AudioChannel) {
        guard !isPaused else { return }
        switch channel {
        case .mic: micSamples.append(contentsOf: samples)
        case .system: systemSamples.append(contentsOf: samples)
        }
        transcriber.feed(samples, channel: channel) { [weak self] segment in
            Task { @MainActor in
                guard let self = self else { return }
                self.liveTranscript.append(segment)
                self.triggerLiveSummarization()
            }
        }
    }

    private func triggerLiveSummarization() {
        guard isRecording, !isSummarizingLive else { return }
        let count = liveTranscript.count
        guard count >= 2, (count - lastLiveSummarizedCount) >= 2 else { return }
        isSummarizingLive = true
        let snapshot = liveTranscript

        Task { [weak self, summarizer] in
            let notes = try? await summarizer.summarize(transcript: snapshot)
            guard let self = self else { return }
            self.isSummarizingLive = false
            if let notes = notes {
                self.currentNotes = notes
                self.lastLiveSummarizedCount = count
            }
        }
    }

    func stopMeeting(customTitle: String? = nil) async {
        guard isRecording else { return }
        timerTask?.cancel()
        timerTask = nil
        mic.stop(); systemTap.stop()
        isRecording = false
        isPaused = false
        isSummarizingLive = false

        status = "Finalizing transcript…"
        let finalSegments = await transcriber.finish()
        liveTranscript = finalSegments.sorted { $0.start < $1.start }

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
            if let customTitle = customTitle?.trimmingCharacters(in: .whitespaces), !customTitle.isEmpty {
                meeting.title = customTitle
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
