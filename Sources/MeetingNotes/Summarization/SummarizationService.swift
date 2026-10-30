import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// On-device summarization + action-item extraction via MLX.
/// Long meetings are handled map-reduce style: summarize ~10-minute chunks,
/// then produce final notes from the chunk summaries (keeps prefill short —
/// the bottleneck on-device is prompt processing, not generation).
final class SummarizationService {
    // ~1.8 GB download, cached by MLX in Application Support.
    // Qwen2.5-7B-Instruct-4bit is a big quality jump on 16 GB+ machines.
    private let modelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    private var container: ModelContainer?

    func prepare() async throws -> ModelContainer {
        if let container { return container }
        // Use the HuggingFace convenience macro to load the model container.
        let c = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID)
        )
        container = c
        return c
    }

    /// `attendees` (from the calendar invite) are offered as action-item owners
    /// alongside the transcript's speaker labels. `userNotes` are what the user
    /// typed during the meeting: they steer what the summary focuses on and come
    /// back rewritten as `enhancedNotes`.
    func summarize(
        transcript: [TranscriptSegment],
        attendees: [String] = [],
        userNotes: String = ""
    ) async throws -> MeetingNotes {
        // With no transcript the model has nothing to ground on and hallucinates.
        guard !transcript.isEmpty else {
            throw NSError(domain: "Summarizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to summarize — the transcript is empty"])
        }
        let container = try await prepare()
        let userNotes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesBlock = userNotes.isEmpty ? "" : """


        The note-taker wrote these notes during the meeting:
        \(userNotes)
        """
        let focusLine = userNotes.isEmpty ? "" : " Give extra detail on anything the note-taker's notes mention."

        // 1. Chunk transcript into ~10-minute windows.
        let chunks = chunk(transcript, seconds: 600)

        // 2. Map: summarize each chunk. The user's notes ride along so details on
        // the topics they flagged survive into the chunk summaries.
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = render(chunk)
            let prompt = """
            Summarize this portion (\(i + 1)/\(chunks.count)) of a meeting transcript \
            in 4-6 sentences. Preserve names, decisions, numbers, and commitments exactly.\
            \(focusLine)\(notesBlock)

            Transcript:
            \(text)
            """
            chunkSummaries.append(try await generate(prompt, container: container, maxTokens: 400))
        }

        // 3. Reduce: final structured notes as JSON.
        // No literal placeholder values in the schema: small models copy them
        // verbatim (a summary of "..." / an owner of "Qwen").
        let speakers = Array(Set(transcript.map(\.speaker)).union(attendees)).sorted().joined(separator: ", ")
        let enhancedSpec = userNotes.isEmpty ? "" : """

        - "enhancedNotes": an array of strings — the note-taker's notes rewritten as \
        clear, complete bullet points, in the same order. Keep every point they wrote \
        and add names, numbers and details from the meeting. Do not add points on \
        topics their notes don't mention.

        Treat the note-taker's notes as the most important points of the meeting: \
        the summary, decisions and action items must cover them.
        """
        let reducePrompt = """
        You are an expert meeting notetaker. Based on these meeting section summaries, \
        respond with ONLY a JSON object (no markdown fences) with exactly these keys:
        - "summary": a 3-5 sentence summary of what was discussed and agreed.
        - "keyDecisions": an array of short strings, one per decision made.
        - "actionItems": an array of objects with "owner" (the person responsible — \
        one of: \(speakers), or a name mentioned in the meeting), "task", and "due" \
        (the deadline as stated, or null).\(enhancedSpec)\(notesBlock)

        Section summaries:
        \(chunkSummaries.enumerated().map { "Section \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n"))
        """
        let raw = try await generate(reducePrompt, container: container, maxTokens: userNotes.isEmpty ? 800 : 1200)
        var notes = try parse(raw)
        if Self.isPlaceholder(notes.summary) {
            notes.summary = chunkSummaries.joined(separator: " ")
        }
        notes.keyDecisions.removeAll(where: Self.isPlaceholder)
        notes.actionItems.removeAll { Self.isPlaceholder($0.task) }
        if userNotes.isEmpty {
            notes.enhancedNotes = nil
        } else {
            let enhanced = (notes.enhancedNotes ?? []).filter { !Self.isPlaceholder($0) }
            // If the model skipped the key, fall back to the user's own lines.
            notes.enhancedNotes = enhanced.isEmpty
                ? userNotes.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•*"))) }
                    .filter { !$0.isEmpty }
                : enhanced
        }
        return notes
    }


    /// True for empty strings or template echoes like "...".
    private static func isPlaceholder(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…"))).isEmpty
    }

    /// Answers `question` using only the given meeting excerpts (retrieval-augmented).
    /// Excerpts are numbered so the model can cite them as [1], [2], …
    func answer(question: String, excerpts: [(source: String, text: String)]) async throws -> String {
        let container = try await prepare()
        let context = excerpts.enumerated()
            .map { "[\($0.offset + 1)] (\($0.element.source))\n\($0.element.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        You answer questions about the user's past meetings. Use ONLY the excerpts below. \
        If they don't contain the answer, say you couldn't find it in the meetings — do not guess. \
        Be concise (2-5 sentences or a short list). Cite excerpts you used like [1] or [2][3].

        Excerpts:
        \(context)

        Question: \(question)
        """
        return try await generate(prompt, container: container, maxTokens: 500)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Proposes which attendee each anonymous speaker label is, from cues in the
    /// transcript. Returns the model's raw proposal (label → name or nil);
    /// callers must validate it with `SpeakerLabeler.validatedMapping`.
    func inferSpeakerNames(transcript: [TranscriptSegment], labels: [String], attendees: [String]) async throws -> [String: String?] {
        let container = try await prepare()
        // Introductions and names used in address cluster early; keep the prompt short.
        var lines: [String] = []
        var length = 0
        for seg in transcript {
            let line = "\(seg.speaker): \(seg.text)"
            length += line.count
            if length > 6_000 { break }
            lines.append(line)
        }
        let prompt = """
        This meeting transcript uses anonymous speaker labels. "You" is the person \
        recording — never map "You". The people invited were: \(attendees.joined(separator: ", ")).

        For each of these labels: \(labels.joined(separator: ", ")) — decide which invited \
        person it is, using ONLY direct evidence in the text: people addressing each other \
        by name ("Thanks, Priya" means the previous speaker is Priya; "Arun, can you…" \
        means the next speaker is probably Arun) or someone introducing themselves. \
        If there is no clear evidence for a label, use null. Never give the same name to two labels.

        Respond with ONLY a JSON object mapping each label to a name or null, for example \
        {"Speaker 1": "Name", "Speaker 2": null}.

        Transcript:
        \(lines.joined(separator: "\n"))
        """
        let raw = try await generate(prompt, container: container, maxTokens: 200)
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else { return [:] }
        return (try? JSONDecoder().decode([String: String?].self, from: Data(raw[start...end].utf8))) ?? [:]
    }

    private func generate(_ prompt: String, container: ModelContainer, maxTokens: Int) async throws -> String {
        try await container.perform { context in   // CHECK-API
            let input = try await context.processor.prepare(
                input: .init(messages: [["role": "user", "content": prompt]])
            )
            let result = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3),
                context: context
            ) { (tokens: [Int]) in Task.isCancelled ? .stop : .more }
            return result.output
        }
    }

    private func chunk(_ segments: [TranscriptSegment], seconds: Double) -> [[TranscriptSegment]] {
        guard !segments.isEmpty else { return [] }
        var out: [[TranscriptSegment]] = []; var current: [TranscriptSegment] = []
        var windowStart = segments.first!.start
        for seg in segments {
            if seg.start - windowStart > seconds, !current.isEmpty {
                out.append(current); current = []; windowStart = seg.start
            }
            current.append(seg)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func render(_ segments: [TranscriptSegment]) -> String {
        segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    private func parse(_ raw: String) throws -> MeetingNotes {
        // Models sometimes wrap JSON in fences or prose — extract outer braces.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw NSError(domain: "Summarizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No JSON in model output"])
        }
        let data = Data(raw[start...end].utf8)
        return try JSONDecoder().decode(MeetingNotes.self, from: data)
    }
}
