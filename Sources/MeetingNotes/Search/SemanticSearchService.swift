import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// On-device semantic search over past meetings using EmbeddingGemma (via MLX).
///
/// Each meeting is split into passages (the AI notes + ~1,200-character transcript
/// windows). A meeting's relevance to a query is its best-matching passage.
/// Vectors are cached on disk next to the meetings and keyed by a fingerprint of
/// the passage text, so only new or edited meetings are re-embedded.
actor SemanticSearchService {
    // ~330 MB download, cached by the Hugging Face hub client like the LLM.
    // The 4-bit variant is ~half the size with slightly weaker retrieval.
    private let modelID = "mlx-community/embeddinggemma-300m-8bit"

    /// Passages longer than this are truncated. EmbeddingGemma supports 2,048,
    /// but shorter inputs keep indexing fast and passages are already small.
    private let maxTokens = 512
    private let maxPassagesPerMeeting = 60
    private let passageCharacters = 1_200

    private var container: EmbedderModelContainer?
    private var index: [UUID: IndexedMeeting] = [:]
    private var isIndexing = false
    private var needsAnotherPass: [Meeting]?
    private let indexURL: URL

    private struct IndexedMeeting: Codable {
        var fingerprint: UInt64
        var vectors: [[Float]]
        /// Text for each vector, used as context when answering questions.
        /// Optional so indexes written before "Ask" existed still decode; those
        /// entries are re-embedded on the next sync.
        var passages: [String]?
    }

    /// A transcript/notes excerpt that matched a query.
    struct Passage: Sendable {
        let meetingID: UUID
        let text: String
        let score: Float
    }

    init(directory: URL) {
        indexURL = directory.appendingPathComponent("embeddings.json")
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([UUID: IndexedMeeting].self, from: data) {
            index = saved
        }
    }

    // MARK: - Public API

    /// Brings the index in line with `meetings`: embeds new/changed meetings and
    /// drops deleted ones. Safe to call often — unchanged meetings are skipped.
    func sync(with meetings: [Meeting]) async {
        // Coalesce overlapping calls: finish the current pass, then run once more
        // with the latest snapshot.
        if isIndexing {
            needsAnotherPass = meetings
            return
        }
        isIndexing = true
        defer { isIndexing = false }

        var snapshot = meetings
        while true {
            await indexPass(snapshot)
            guard let next = needsAnotherPass else { break }
            needsAnotherPass = nil
            snapshot = next
        }
    }

    /// Returns each indexed meeting's best cosine similarity to `query`.
    func scores(for query: String) async throws -> [UUID: Float] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !index.isEmpty else { return [:] }

        let q = try await embed("task: search result | query: \(trimmed)")
        var result: [UUID: Float] = [:]
        for (id, entry) in index {
            // Vectors are L2-normalized by the model, so dot product = cosine.
            result[id] = entry.vectors.map { dot($0, q) }.max() ?? 0
        }
        return result
    }

    /// The `limit` best-matching passages across all meetings, best first.
    /// Passages scoring below `minScore` are dropped.
    func topPassages(for query: String, limit: Int, minScore: Float) async throws -> [Passage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !index.isEmpty else { return [] }

        let q = try await embed("task: question answering | query: \(trimmed)")
        var matches: [Passage] = []
        for (id, entry) in index {
            guard let passages = entry.passages, passages.count == entry.vectors.count else { continue }
            for (vector, text) in zip(entry.vectors, passages) {
                let score = dot(vector, q)
                if score >= minScore {
                    matches.append(Passage(meetingID: id, text: text, score: score))
                }
            }
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Indexing

    private func indexPass(_ meetings: [Meeting]) async {
        let liveIDs = Set(meetings.map(\.id))
        var changed = false

        for id in index.keys where !liveIDs.contains(id) {
            index[id] = nil
            changed = true
        }

        for meeting in meetings {
            let passages = Self.passages(for: meeting, chunkSize: passageCharacters, limit: maxPassagesPerMeeting)
            let fingerprint = Self.fingerprint(passages)
            if let existing = index[meeting.id], existing.fingerprint == fingerprint, existing.passages != nil {
                continue
            }
            do {
                var vectors: [[Float]] = []
                for passage in passages {
                    vectors.append(try await embed("title: none | text: \(passage)"))
                }
                index[meeting.id] = IndexedMeeting(fingerprint: fingerprint, vectors: vectors, passages: passages)
                changed = true
            } catch {
                NSLog("SemanticSearch: failed to embed meeting \(meeting.id): \(error)")
            }
        }

        if changed { persist() }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("SemanticSearch: failed to save index: \(error)")
        }
    }

    // MARK: - Model

    private func prepare() async throws -> EmbedderModelContainer {
        if let container { return container }
        let c = try await EmbedderModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: modelID)
        )
        container = c
        return c
    }

    /// Embeds one text. Inputs are embedded one at a time (no padding) because the
    /// Gemma backbone isn't given an attention mask, so padded batches would let
    /// pad tokens leak into real tokens' representations.
    private func embed(_ text: String) async throws -> [Float] {
        let container = try await prepare()
        let maxTokens = self.maxTokens
        return try await container.perform { context in
            let tokens = context.tokenizer.encode(text: text, addSpecialTokens: true).prefix(maxTokens)
            let input = MLXArray(tokens.map { Int32($0) }).reshaped(1, -1)
            let output = context.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
            // EmbeddingGemma's pooled output is already mean-pooled, projected and L2-normalized.
            guard let pooled = output.pooledOutput else { return [] }
            pooled.eval()
            return pooled[0].asArray(Float.self)
        }
    }

    // MARK: - Helpers

    /// Text that represents a meeting for search: AI notes first, then the transcript
    /// in fixed-size windows. Titles and speaker labels are left out on purpose so
    /// renames don't trigger re-embedding (keyword search still covers them).
    static func passages(for meeting: Meeting, chunkSize: Int, limit: Int) -> [String] {
        var passages: [String] = []

        if let notes = meeting.notes {
            var parts = [notes.summary]
            parts += notes.keyDecisions.map { "Decision: \($0)" }
            parts += notes.actionItems.map { "Action item: \($0.task)" }
            parts += (notes.enhancedNotes ?? []).map { "Note: \($0)" }
            let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { passages.append(text) }
        }

        if let userNotes = meeting.userNotes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userNotes.isEmpty {
            passages.append(String(userNotes.prefix(chunkSize)))
        }

        var current = ""
        for segment in meeting.transcript {
            let line = segment.text.cleanedTranscript
            guard !line.isEmpty else { continue }
            if current.count + line.count > chunkSize, !current.isEmpty {
                passages.append(current)
                current = ""
            }
            current += current.isEmpty ? line : " " + line
        }
        if !current.isEmpty { passages.append(current) }

        return Array(passages.prefix(limit))
    }

    /// Stable across launches (unlike `Hasher`), so it can be persisted. FNV-1a 64-bit.
    private static func fingerprint(_ passages: [String]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in passages.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }
}
