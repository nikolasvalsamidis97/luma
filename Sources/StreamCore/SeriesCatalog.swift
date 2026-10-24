import Foundation

/// One instance per account/session. Bounds network work and memory for large libraries.
public actor SeriesCatalog {
    private struct Entry { let value: SeriesDetails; let date: Date; var accessed: Date }
    private struct Flight { let id: UUID; let task: Task<SeriesDetails, Error>; var waiters: Set<UUID> }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    private let gate: RequestGate
    private let loader: @Sendable (MediaItem) async throws -> SeriesDetails
    private let lifetime: TimeInterval
    private let capacity: Int
    private let refusalBackoff: TimeInterval
    private var refusal: (error: ProviderError, until: Date)?
    public init(client: XtreamClient) {
        loader = { try await client.seriesDetails(series: $0) }
        gate = RequestGate(limit: 1, minimumInterval: 0.5); lifetime = 1800; capacity = 128; refusalBackoff = 30
    }
    public init(limit: Int = 3, lifetime: TimeInterval = 1800, capacity: Int = 128,
                minimumInterval: TimeInterval = 0, refusalBackoff: TimeInterval = 30,
                loader: @escaping @Sendable (MediaItem) async throws -> SeriesDetails) {
        self.loader = loader; gate = RequestGate(limit: max(1, limit), minimumInterval: max(0, minimumInterval))
        self.refusalBackoff = max(0, refusalBackoff)
        self.lifetime = lifetime; self.capacity = max(1, capacity)
    }
    public func details(for item: MediaItem) async throws -> SeriesDetails {
        try Task.checkCancellation()
        let key = item.streamID
        if var entry = entries[key], Date().timeIntervalSince(entry.date) < lifetime {
            entry.accessed = Date(); entries[key] = entry; return entry.value
        }
        entries[key] = nil
        let waiter = UUID()
        if flights[key] == nil {
            let gate = self.gate
            let task = Task { try await gate.perform { try await self.load(item) } }
            flights[key] = Flight(id: UUID(), task: task, waiters: [])
        }
        flights[key]!.waiters.insert(waiter)
        let flight = flights[key]!
        return try await withTaskCancellationHandler {
            do {
                let result = try await flight.task.value
                try Task.checkCancellation()
                if flights[key]?.id == flight.id {
                    entries[key] = Entry(value: result, date: Date(), accessed: Date())
                    if entries.count > capacity, let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key { entries[oldest] = nil }
                }
                removeWaiter(waiter, key: key, flight: flight.id)
                return result
            } catch {
                removeWaiter(waiter, key: key, flight: flight.id)
                throw error
            }
        } onCancel: {
            Task { await self.removeWaiter(waiter, key: key, flight: flight.id) }
        }
    }
    private func load(_ item: MediaItem) async throws -> SeriesDetails {
        // A refusal applies to the provider session, not just one thumbnail. Do not
        // turn a grid of cards into a burst of further rejected requests.
        if let refusal, Date() < refusal.until { throw refusal.error }
        do {
            let result = try await loader(item)
            refusal = nil
            return result
        } catch let error as ProviderError {
            if case .http(let status) = error, status == 403 || status == 429 {
                refusal = (error, Date().addingTimeInterval(refusalBackoff))
            }
            throw error
        }
    }
    private func removeWaiter(_ waiter: UUID, key: String, flight: UUID) {
        guard flights[key]?.id == flight else { return }
        flights[key]?.waiters.remove(waiter)
        if flights[key]?.waiters.isEmpty == true { flights.removeValue(forKey: key)?.task.cancel() }
    }
}

private actor RequestGate {
    private let limit: Int
    private var active = 0
    private let minimumInterval: TimeInterval
    private var lastStart: Date?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int, minimumInterval: TimeInterval) { self.limit = limit; self.minimumInterval = minimumInterval }
    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            if let lastStart {
                let delay = minimumInterval - Date().timeIntervalSince(lastStart)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
            try Task.checkCancellation()
            lastStart = Date()
            let result = try await operation()
            release(); return result
        } catch { release(); throw error }
    }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}
