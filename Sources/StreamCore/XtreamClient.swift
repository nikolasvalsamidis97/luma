import Foundation

public struct XtreamClient: Sendable {
    public let credentials: Credentials
    private let session: URLSession
    // Keep the provider-facing identity stable across app releases.
    static let providerUserAgent = "Luma/0.3"
    public init(credentials: Credentials, session: URLSession? = nil) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: config)
    }
    private func request(action: String? = nil, parameters: [String: String] = [:]) async throws -> JSONValue {
        do {
            var request = URLRequest(url: credentials.apiURL(action: action, parameters: parameters))
            request.setValue(Self.providerUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw ProviderError.invalidResponse }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProviderError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ProviderError.network }
    }
    public func authenticate() async throws {
        let json = try await request()
        guard json["user_info"]["auth"].string == "1" else { throw ProviderError.unauthorized }
        if let status = json["user_info"]["status"].string, status.lowercased() != "active" { throw ProviderError.inactive }
    }
    public func library(_ kind: LibraryKind) async throws -> ([StreamCategory], [MediaItem]) {
        async let categoryJSON = request(action: kind.categoryAction)
        async let itemJSON = request(action: kind.action)
        let (cats, items) = try await (categoryJSON, itemJSON)
        guard let rows = items.array, let categories = cats.array else { throw ProviderError.invalidResponse }
        let parsed = rows.compactMap { MediaItem.parse($0, kind: kind) }
        var seen = Set<String>()
        return (categories.compactMap { j in
            guard let id = j["category_id"].string, let name = j["category_name"].string else { return nil }
            return StreamCategory(id: id, name: name)
        }, parsed.filter { seen.insert($0.id).inserted })
    }
    public func seriesDetails(series: MediaItem) async throws -> SeriesDetails {
        let json = try await request(action: "get_series_info", parameters: ["series_id": series.streamID])
        return try SeriesDetails.parse(json, series: series)
    }
    public func episodes(series: MediaItem) async throws -> [MediaItem] {
        try await seriesDetails(series: series).episodes
    }
    public func guide(for item: MediaItem) async throws -> [GuideEntry] {
        let json = try await request(action: "get_short_epg", parameters: ["stream_id": item.streamID, "limit": "8"])
        return (json["epg_listings"].array ?? []).compactMap { j in
            guard let start = j["start_timestamp"].string.flatMap(Double.init), let end = j["stop_timestamp"].string.flatMap(Double.init) else { return nil }
            let raw = j["title"].string ?? "Untitled programme"
            let title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
            return GuideEntry(id: j["id"].string ?? String(start), title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
        }.sorted { $0.start < $1.start }
    }
}
