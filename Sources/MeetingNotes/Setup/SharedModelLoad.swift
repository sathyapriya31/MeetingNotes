import Foundation

/// Loads a model once and shares the in-flight load with every caller, so the
/// launch-time preload and a real use (summarize, search) never load the same
/// weights twice. A failed load is forgotten so the next call retries it.
final class SharedModelLoad<Value: Sendable>: @unchecked Sendable {
    typealias Progress = @Sendable (Double) -> Void

    private let lock = NSLock()
    private var task: Task<Value, Error>?
    private var observer: Progress?
    private let load: @Sendable (@escaping Progress) async throws -> Value

    init(_ load: @escaping @Sendable (_ progress: @escaping Progress) async throws -> Value) {
        self.load = load
    }

    /// The loaded value. `progress` (0...1, download fraction) replaces any
    /// earlier observer and receives updates from the shared load.
    func value(progress: Progress? = nil) async throws -> Value {
        let task: Task<Value, Error> = lock.withLock {
            if let progress { observer = progress }
            if let existing = self.task { return existing }
            let new = Task { try await self.load { [weak self] fraction in self?.report(fraction) } }
            self.task = new
            return new
        }
        do {
            return try await task.value
        } catch {
            lock.withLock { if self.task == task { self.task = nil } }
            throw error
        }
    }

    private func report(_ fraction: Double) {
        let observer = lock.withLock { self.observer }
        observer?(fraction)
    }
}
