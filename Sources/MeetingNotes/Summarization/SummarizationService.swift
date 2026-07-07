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

    private func prepare() async throws -> ModelContainer {
        if let container { return container }
        // Use the HuggingFace convenience macro to load the model container.
        let c = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID)
        )
        container = c
        return c
    }

    func summarize(transcript: [TranscriptSegment]) async throws -> MeetingNotes {
        let container = try await prepare()

        // 1. Chunk transcript into ~10-minute windows.
        let chunks = chunk(transcript, seconds: 600)

        // 2. Map: summarize each chunk.
        var chunkSummaries: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let text = render(chunk)
            let prompt = """
            Summarize this portion (\(i + 1)/\(chunks.count)) of a meeting transcript \
            in 4-6 sentences. Preserve names, decisions, numbers, and commitments exactly.

            \(text)
            """
            chunkSummaries.append(try await generate(prompt, container: container, maxTokens: 400))
        }

        // 3. Reduce: final structured notes as JSON.
        let reducePrompt = """
        You are an expert meeting notetaker. Based on these meeting section summaries, \
        respond with ONLY a JSON object, no markdown fences, matching exactly:
        {"summary": "...", "keyDecisions": ["..."], \
        "actionItems": [{"owner": "...", "task": "...", "due": "..." or null}]}

        Section summaries:
        \(chunkSummaries.enumerated().map { "Section \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n"))
        """
        let raw = try await generate(reducePrompt, container: container, maxTokens: 800)
        return try parse(raw)
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
            ) { (tokens: [Int]) in .more }
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
