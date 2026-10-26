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

    func summarize(transcript: [TranscriptSegment]) async throws -> MeetingNotes {
        // With no transcript the model has nothing to ground on and hallucinates.
        guard !transcript.isEmpty else {
            throw NSError(domain: "Summarizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to summarize — the transcript is empty"])
        }
        let container = try await prepare()

        // 1. Chunk transcript into ~10-minute windows.
        let chunks = chunk(transcript, seconds: 600)

        // 2. Map: summarize each chunk.
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = render(chunk)
            let prompt = """
            Summarize this portion (\(i + 1)/\(chunks.count)) of a meeting transcript \
            in 4-6 sentences. Preserve names, decisions, numbers, and commitments exactly.

            \(text)
            """
            chunkSummaries.append(try await generate(prompt, container: container, maxTokens: 400))
        }

        // 3. Reduce: final structured notes as JSON.
        // No literal placeholder values in the schema: small models copy them
        // verbatim (a summary of "..." / an owner of "Qwen").
        let speakers = Array(Set(transcript.map(\.speaker))).sorted().joined(separator: ", ")
        let reducePrompt = """
        You are an expert meeting notetaker. Based on these meeting section summaries, \
        respond with ONLY a JSON object (no markdown fences) with exactly these keys:
        - "summary": a 3-5 sentence summary of what was discussed and agreed.
        - "keyDecisions": an array of short strings, one per decision made.
        - "actionItems": an array of objects with "owner" (the person responsible — \
        one of: \(speakers), or a name mentioned in the meeting), "task", and "due" \
        (the deadline as stated, or null).

        Section summaries:
        \(chunkSummaries.enumerated().map { "Section \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n"))
        """
        let raw = try await generate(reducePrompt, container: container, maxTokens: 800)
        var notes = try parse(raw)
        if Self.isPlaceholder(notes.summary) {
            notes.summary = chunkSummaries.joined(separator: " ")
        }
        notes.keyDecisions.removeAll(where: Self.isPlaceholder)
        notes.actionItems.removeAll { Self.isPlaceholder($0.task) }
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
