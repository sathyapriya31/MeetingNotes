import Foundation
import Voz

/// Per-channel sample buffers. Lock-protected (rather than an actor) so appends
/// happen synchronously and in arrival order.
final class TranscriptionBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: [Float] = []
    private var system: [Float] = []

    func append(_ s: [Float], to channel: AudioChannel) {
        lock.lock(); defer { lock.unlock() }
        switch channel {
        case .mic: mic.append(contentsOf: s)
        case .system: system.append(contentsOf: s)
        }
    }

    func drain(_ channel: AudioChannel, keepLast: Int = 0) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        switch channel {
        case .mic:
            let out = mic
            mic = Array(mic.suffix(keepLast))
            return out
        case .system:
            let out = system
            system = Array(system.suffix(keepLast))
            return out
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        mic.removeAll()
        system.removeAll()
    }
}

/// Near-live transcription using Desert Ant Labs "Voz" (running on Apple Neural Engine).
/// Buffers each channel and transcribes in short overlapping windows.
/// Two channels are kept apart so mic = "You" and system = "Them" before diarization runs.
///
/// All transcription runs on a single loop task, so windows are processed
/// strictly one after another — `elapsed` / `allSegments` are never touched
/// concurrently.
final class TranscriptionService {
    private var voz: Voz?
    private let buffers = TranscriptionBuffers()
    private var loopTask: Task<Void, Never>?
    private var onSegment: ((TranscriptSegment) -> Void)?
    private var elapsed: [AudioChannel: Double] = [.mic: 0, .system: 0]
    private var lastText: [AudioChannel: String] = [:]
    private var allSegments: [TranscriptSegment] = []
    private let windowSeconds: Double = 3.0
    private let overlapSeconds: Double = 0.5
    private let sampleRate: Double = 16_000

    /// Loads the Voz model on the Apple Neural Engine, downloading it if not present.
    /// `progress` receives the download fraction (0...1).
    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard voz == nil else { return }
        if !Voz.isDownloaded() {
            try await Voz.download(progress: { progress($0.fraction) })
        }
        voz = try await Voz()
    }

    /// Clears all state from any previous meeting and starts the transcription loop.
    func start(onSegment: @escaping (TranscriptSegment) -> Void) {
        loopTask?.cancel()
        buffers.removeAll()
        elapsed = [.mic: 0, .system: 0]
        lastText = [:]
        allSegments = []
        self.onSegment = onSegment

        let interval = UInt64(windowSeconds * 1_000_000_000)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                await self.transcribePending()
            }
        }
    }

    func feed(_ samples: [Float], channel: AudioChannel) {
        buffers.append(samples, to: channel)
    }

    private func transcribePending() async {
        for channel in [AudioChannel.mic, .system] {
            let audio = buffers.drain(channel, keepLast: Int(sampleRate * overlapSeconds))
            guard audio.count > Int(sampleRate * 0.5) else { continue } // skip < 0.5 s

            let base = elapsed[channel] ?? 0
            let kept = min(audio.count, Int(sampleRate * overlapSeconds))
            elapsed[channel] = base + Double(audio.count - kept) / sampleRate

            guard let voz else { continue }
            do {
                let result = try await voz.transcribe(samples: audio)
                let raw = result.text.cleanedTranscript
                // The leading overlap was already transcribed at the end of the
                // previous window — drop words repeated across the boundary.
                let text = Self.stripRepeatedPrefix(raw, previous: lastText[channel] ?? "")
                guard !text.isEmpty else { continue }
                lastText[channel] = raw

                let segment = TranscriptSegment(
                    start: base,
                    end: base + Double(audio.count) / sampleRate,
                    speaker: channel == .mic ? "You" : "Them",
                    channel: channel,
                    text: text
                )
                allSegments.append(segment)
                onSegment?(segment)
            } catch {
                print("Voz transcription error on channel \(channel): \(error)")
            }
        }
    }

    /// Flush remaining audio and return all transcribed segments.
    func finish() async -> [TranscriptSegment] {
        loopTask?.cancel()
        await loopTask?.value          // let any in-flight window complete first
        loopTask = nil
        await transcribePending()
        onSegment = nil
        return allSegments
    }

    /// Removes the longest run of leading words in `text` (2–6 words) that equals
    /// the trailing words of `previous`, ignoring case and punctuation. Single
    /// words aren't stripped — a lone "the"/"and" repeat is usually genuine.
    static func stripRepeatedPrefix(_ text: String, previous: String) -> String {
        let words = text.split(separator: " ").map(String.init)
        let prevWords = previous.split(separator: " ").map(String.init)
        guard !words.isEmpty, !prevWords.isEmpty else { return text }

        func norm(_ w: String) -> String {
            w.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let maxK = min(6, words.count, prevWords.count)
        guard maxK >= 2 else { return text }
        for k in stride(from: maxK, through: 2, by: -1) {
            let head = words.prefix(k).map(norm)
            let tail = prevWords.suffix(k).map(norm)
            if head == tail, !head.allSatisfy(\.isEmpty) {
                return words.dropFirst(k).joined(separator: " ")
            }
        }
        return text
    }
}
