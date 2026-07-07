import SwiftUI

@main
struct MeetingNotesApp: App {
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
    }
}

/// Orchestrates the whole pipeline:
/// capture → transcribe (live) → diarize (post) → summarize (post).
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript: [TranscriptSegment] = []
    @Published var currentNotes: MeetingNotes?
    @Published var status: String = "Idle"
    @Published var lastSavedMeetingID: UUID?

    let store = MeetingStore()
    private var meetingStart: Date?

    private let mic = MicCapture()
    private let systemTap = SystemAudioTap()
    private let transcriber = TranscriptionService()
    private let diarizer = DiarizationService()
    private let summarizer = SummarizationService()

    // Raw 16 kHz mono buffers kept for post-meeting diarization.
    private var micSamples: [Float] = []
    private var systemSamples: [Float] = []

    func startMeeting() async {
        guard !isRecording else { return }
        status = "Loading models…"
        do {
            try await transcriber.prepare()   // downloads Whisper on first run
            status = "Recording"
            isRecording = true
            meetingStart = Date()
            micSamples.removeAll(); systemSamples.removeAll()
            liveTranscript.removeAll(); currentNotes = nil

            // Two channels: mic = "You", system tap = "Them".
            try mic.start { [weak self] samples in
                Task { @MainActor in self?.ingest(samples, channel: .mic) }
            }
            try systemTap.start { [weak self] samples in
                Task { @MainActor in self?.ingest(samples, channel: .system) }
            }
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
            isRecording = false
        }
    }

    private func ingest(_ samples: [Float], channel: AudioChannel) {
        switch channel {
        case .mic: micSamples.append(contentsOf: samples)
        case .system: systemSamples.append(contentsOf: samples)
        }
        transcriber.feed(samples, channel: channel) { [weak self] segment in
            Task { @MainActor in self?.liveTranscript.append(segment) }
        }
    }

    func stopMeeting() async {
        guard isRecording else { return }
        mic.stop(); systemTap.stop()
        isRecording = false

        status = "Finalizing transcript…"
        let finalSegments = await transcriber.finish()
        liveTranscript = finalSegments.sorted { $0.start < $1.start }

        status = "Identifying speakers…"
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
            let meeting = Meeting(date: meetingStart ?? Date(), transcript: liveTranscript, notes: currentNotes)
            store.save(meeting)
            liveTranscript = []
            currentNotes = nil
            lastSavedMeetingID = meeting.id
        }
    }
}

enum AudioChannel: String, Codable { case mic, system }
