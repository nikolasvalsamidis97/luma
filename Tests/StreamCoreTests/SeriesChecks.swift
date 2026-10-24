import Foundation
import StreamCore

extension StreamCoreChecks {
    func testSeasonAvailability() throws {
        let series = MediaItem(streamID: "1", kind: .series, name: "Duplicate title")
        func parse(_ text: String) throws -> SeriesDetails {
            try SeriesDetails.parse(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), series: series)
        }
        let details = try parse(#"{"seasons":[{"season_number":1},{"season_number":2},{"season_number":3},{"season_number":4}],"episodes":{"0":[{"id":"special"}],"1":[{"id":11},{"id":12,"season":"1"}],"3":[{"id":31,"season":3}],"4":[]}}"#)
        precondition(details.availability.badge == "2 seasons", "Count distinct nonempty seasons, not the maximum season or metadata list")
        precondition(details.availability.hasSpecials)
        precondition(details.episodes.first?.season == 0)
        let single = try parse(#"{"episodes":{"2":[{"id":"21"},{"id":"22"}]}}"#)
        precondition(single.availability.badge == "1 season", "Fallback to dictionary season when episodes omit season")
        let specials = try parse(#"{"episodes":{"0":[{"id":1}]}}"#)
        precondition(specials.availability.badge == "Specials only")
        let empty = try parse(#"{"episodes":[]}"#)
        precondition(empty.availability.badge == "0 seasons")
        let unknown = try parse(#"{"episodes":[[{"id":1}]]}"#)
        precondition(unknown.availability.badge == "Seasons unknown", "Do not invent a season when provider data is missing")
        let nested = try parse(#"{"episodes":[[{"id":1,"season":"1"}],[{"id":2,"season":2}]]}"#)
        precondition(nested.availability.badge == "2 seasons")
        let flat = try parse(#"{"episodes":[{"id":1,"season":1},{"id":2,"season":1}]}"#)
        precondition(flat.availability.badge == "1 season")
        for malformed in [#"{"seasons":[]}"#, #"{"episodes":{"1":null}}"#, #"{"episodes":{"1":[{"title":"Missing ID"}]}}"#] {
            do { _ = try parse(malformed); preconditionFailure("Malformed metadata must not look like zero seasons") }
            catch is ProviderError { }
        }
    }
    func testSeriesCatalog() async throws {
        let probe = SeriesRequestProbe()
        let catalog = SeriesCatalog(loader: { try await probe.load($0) })
        let item = MediaItem(streamID: "same", kind: .series, name: "Show")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<15 { group.addTask { _ = try await catalog.details(for: item) } }
            try await group.waitForAll()
        }
        _ = try await catalog.details(for: item)
        let coalesced = await probe.calls(for: "same")
        precondition(coalesced == 1, "Cards and detail view must share one request and cached result")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<15 {
                group.addTask { _ = try await catalog.details(for: MediaItem(streamID: "id\(i)", kind: .series, name: "Same title")) }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak
        precondition(peak <= 3 && peak > 1, "Cap simultaneous provider requests at three")

        let cancellationProbe = SeriesRequestProbe()
        let serial = SeriesCatalog(limit: 1, loader: { try await cancellationProbe.load($0) })
        let blocker = Task { try await serial.details(for: MediaItem(streamID: "blocker", kind: .series, name: "Show")) }
        while await cancellationProbe.calls(for: "blocker") == 0 { await Task.yield() }
        let queued = Task { try await serial.details(for: MediaItem(streamID: "cancelled", kind: .series, name: "Show")) }
        try await Task.sleep(for: .milliseconds(10))
        queued.cancel()
        _ = try await blocker.value
        do { _ = try await queued.value; preconditionFailure("Cancelled card must not receive a result") }
        catch is CancellationError { }
        let cancelledCalls = await cancellationProbe.calls(for: "cancelled")
        precondition(cancelledCalls == 0, "An offscreen queued card must not contact the provider")

        let firstWaiter = Task { try await serial.details(for: item) }
        let secondWaiter = Task { try await serial.details(for: item) }
        try await Task.sleep(for: .milliseconds(20)); firstWaiter.cancel()
        _ = try await secondWaiter.value
        let sharedCalls = await cancellationProbe.calls(for: "same")
        precondition(sharedCalls == 1, "Cancelling one card must not cancel a detail view sharing its request")

        let fresh = SeriesCatalog(loader: { try await probe.load($0) })
        _ = try await fresh.details(for: item)
        let newSessionCalls = await probe.calls(for: "same")
        precondition(newSessionCalls == 2, "A new account/session must have an independent cache")
        let expired = SeriesCatalog(lifetime: 0, loader: { try await probe.load($0) })
        _ = try await expired.details(for: item); _ = try await expired.details(for: item)
        let expiryCalls = await probe.calls(for: "same")
        precondition(expiryCalls == 4, "Expired counts must be fetched again")
    }
}

private actor SeriesRequestProbe {
    private var counts: [String: Int] = [:]
    private var active = 0
    private(set) var peak = 0
    func calls(for key: String) -> Int { counts[key, default: 0] }
    func load(_ item: MediaItem) async throws -> SeriesDetails {
        counts[item.streamID, default: 0] += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(120))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"episodes":{"1":[{"id":"11"}],"2":[{"id":"21"}]}}"#.utf8))
        return try SeriesDetails.parse(json, series: item)
    }
}

extension StreamCoreChecks {
    func testSeriesRefusalRecovery() async throws {
        let probe = RefusalProbe()
        let catalog = SeriesCatalog(limit: 1, refusalBackoff: 0.15, loader: { try await probe.load($0) })
        let item = MediaItem(streamID: "refused", kind: .series, name: "Show")
        for id in ["refused", "another"] {
            do {
                _ = try await catalog.details(for: MediaItem(streamID: id, kind: .series, name: "Show"))
                preconditionFailure("HTTP 403 must stay a fetch error, never an unknown or zero season count")
            } catch ProviderError.http(let status) { precondition(status == 403) }
        }
        let callsAfterRefusal = await probe.calls
        precondition(callsAfterRefusal == 1, "Other cards must not hammer a provider that has refused access")
        try await Task.sleep(for: .milliseconds(180))
        let recovered = try await catalog.details(for: item)
        precondition(recovered.availability.badge == "2 seasons", "A failed lookup must be retryable after access returns")
        _ = try await catalog.details(for: item)
        let totalCalls = await probe.calls
        precondition(totalCalls == 2, "Cache successful recovery normally")

        let pacedProbe = RefusalProbe(failFirst: false)
        let paced = SeriesCatalog(limit: 1, minimumInterval: 0.08, loader: { try await pacedProbe.load($0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<3 { group.addTask { _ = try await paced.details(for: MediaItem(streamID: String(id), kind: .series, name: "Show")) } }
            try await group.waitForAll()
        }
        let starts = await pacedProbe.starts
        precondition(zip(starts, starts.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 0.07 }, "Space background lookups apart")
    }
}

private actor RefusalProbe {
    private(set) var calls = 0
    private(set) var starts: [Date] = []
    let failFirst: Bool
    init(failFirst: Bool = true) { self.failFirst = failFirst }
    func load(_ item: MediaItem) throws -> SeriesDetails {
        calls += 1; starts.append(Date())
        if failFirst && calls == 1 { throw ProviderError.http(403) }
        return try SeriesDetails.parse(JSONDecoder().decode(JSONValue.self, from: Data(#"{"episodes":{"1":[{"id":11}],"2":[{"id":21}]}}"#.utf8)), series: item)
    }
}
