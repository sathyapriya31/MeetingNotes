import Foundation
import HuggingFace
import Voz
import Who

/// Tracks the four on-device models through download and load, for the
/// first-run setup screen and the sidebar progress row. The work itself is
/// driven by `MeetingCoordinator.preloadModels()`.
@MainActor
final class ModelSetup: ObservableObject {
    enum Model: String, CaseIterable, Identifiable {
        case voz, who, qwen, gemma
        var id: String { rawValue }

        var name: String {
            switch self {
            case .voz: return "Voz"
            case .who: return "Who"
            case .qwen: return "Qwen2.5 3B"
            case .gemma: return "EmbeddingGemma"
            }
        }

        var purpose: String {
            switch self {
            case .voz: return "Speech recognition"
            case .who: return "Speaker identification"
            case .qwen: return "Summaries, action items and answers"
            case .gemma: return "Search by meaning"
            }
        }

        var systemImage: String {
            switch self {
            case .voz: return "waveform"
            case .who: return "person.2.wave.2"
            case .qwen: return "sparkles"
            case .gemma: return "magnifyingglass"
            }
        }

        /// Approximate download size, used for labels and to weight overall progress.
        var megabytes: Double {
            switch self {
            case .voz: return 320
            case .who: return 80
            case .qwen: return 1_600
            case .gemma: return 345
            }
        }

        var huggingFaceRepo: String? {
            switch self {
            case .qwen: return "mlx-community/Qwen2.5-3B-Instruct-4bit"
            case .gemma: return "mlx-community/embeddinggemma-300m-8bit"
            case .voz, .who: return nil
            }
        }

        /// Whether the model files are already on disk (no download needed).
        var isDownloaded: Bool {
            switch self {
            case .voz: return Voz.isDownloaded()
            case .who: return Who.isDownloaded()
            case .qwen, .gemma: return huggingFaceRepo.map(Self.isCachedOnHub) ?? false
            }
        }

        /// The Hugging Face hub cache keeps `models--org--name/snapshots/<rev>/`;
        /// a snapshot with weights in it means the download finished.
        private static func isCachedOnHub(_ repo: String) -> Bool {
            let snapshots = HubCache.default.cacheDirectory
                .appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
                .appendingPathComponent("snapshots")
            let fm = FileManager.default
            let revisions = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
            return revisions.contains { revision in
                let files = (try? fm.contentsOfDirectory(atPath: revision.path)) ?? []
                return files.contains { $0.hasSuffix(".safetensors") }
            }
        }
    }

    enum State: Equatable {
        case waiting
        case downloading(Double)
        /// Downloaded; loading weights / compiling for the Neural Engine.
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var states: [Model: State] = [:]
    /// Models that weren't on disk at launch (checked once; disk checks are too
    /// slow to repeat on every progress update).
    @Published private(set) var toDownload: Set<Model>
    /// Whether the full-window setup screen is showing. On at launch only when
    /// something has to be downloaded.
    @Published var showsSetupScreen: Bool

    init() {
        let missing = Set(Model.allCases.filter { !$0.isDownloaded })
        toDownload = missing
        showsSetupScreen = !missing.isEmpty
        for model in Model.allCases { states[model] = .waiting }
    }

    func state(of model: Model) -> State { states[model] ?? .waiting }

    var isComplete: Bool { Model.allCases.allSatisfy { state(of: $0) == .ready } }

    var hasFailure: Bool {
        Model.allCases.contains { if case .failed = state(of: $0) { return true } else { return false } }
    }

    var isBusy: Bool {
        Model.allCases.contains {
            switch state(of: $0) {
            case .downloading, .loading: return true
            default: return false
            }
        }
    }

    /// Size of the models that still have to be downloaded, in MB.
    var pendingDownloadMegabytes: Double {
        toDownload.map(\.megabytes).reduce(0, +)
    }

    /// 0...1 across all models, weighted by download size.
    var overallProgress: Double {
        let total = Model.allCases.map(\.megabytes).reduce(0, +)
        let done = Model.allCases.map { model -> Double in
            switch state(of: model) {
            case .ready, .loading: return model.megabytes
            case .downloading(let f): return model.megabytes * f
            case .waiting, .failed: return 0
            }
        }.reduce(0, +)
        return total > 0 ? done / total : 0
    }

    /// Runs one model's preparation, reporting its progress. `prepare` gets a
    /// callback for the download fraction; once it reaches 1 the row switches to
    /// "Loading…" until `prepare` returns.
    func run(_ model: Model, prepare: (@escaping @Sendable (Double) -> Void) async throws -> Void) async {
        if state(of: model) == .ready { return }
        states[model] = toDownload.contains(model) ? .downloading(0) : .loading
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.report(fraction, for: model) }
        }
        // Large downloads occasionally stall and time out; retry a couple of
        // times before asking the user to.
        let attempts = 3
        for attempt in 1...attempts {
            do {
                try await prepare(progress)
                states[model] = .ready
                toDownload.remove(model)
                return
            } catch {
                if attempt == attempts || Task.isCancelled {
                    states[model] = .failed(error.localizedDescription)
                } else {
                    try? await Task.sleep(for: .seconds(2 * attempt))
                }
            }
        }
    }

    private func report(_ fraction: Double, for model: Model) {
        switch state(of: model) {
        case .downloading(let current):
            // Progress callbacks can arrive out of order; never move backwards.
            let value = max(current, min(1, fraction))
            states[model] = value >= 1 ? .loading : .downloading(value)
        default:
            break
        }
    }
}
