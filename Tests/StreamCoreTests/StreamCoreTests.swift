import Foundation
import StreamCore

@main struct StreamCoreChecks {
    static func main() async throws {
        let checks = StreamCoreChecks()
        try checks.testCredentialURLsEncodeReservedCharacters()
        try checks.testRejectsMalformedInputsAndPathInjection()
        try checks.testMixedProviderIDsAndMissingArtwork()
        try await checks.testAuthenticationLibraryEpisodesAndGuide()
        try await checks.testInvalidLoginAndNonJSONHaveSafeErrors()
        try checks.testSubtitlePreferences()
        try checks.testSeasonAvailability()
        try await checks.testSeriesCatalog()
        try await checks.testSeriesRefusalRecovery()
        try checks.testMediaTraits()
        checks.testHLSQualities()
        checks.testEpisodeSequence()
        try checks.testViewingLibrary()
        try checks.testLicensingLeases()
        try await checks.testM3U()
        try checks.testSavedPlaylists()
        print("PASS: 16 core check groups — URL encoding, input validation, mixed JSON, provider workflows, safe errors, subtitle preferences, season counts, bounded/cancellable series caching, media badges, HLS quality discovery, provider refusal recovery, next episodes, viewing history, Watchlist bounded licensing leases M3U playlists and multiple saved providers")
    }
    func testCredentialURLsEncodeReservedCharacters() throws {
        let c = try Credentials(server: " https://tv.example:8080/base/player_api.php?old=1 ", username: "a/b +?", password: "p/#%&")
        expectEqual(c.server.absoluteString, "https://tv.example:8080/base")
        expectFalse(c.apiURL().absoluteString.contains("+"))
        let api = URLComponents(url: c.apiURL(action: "get_live_streams"), resolvingAgainstBaseURL: false)!
        expectEqual(api.queryItems?.first(where: { $0.name == "username" })?.value, "a/b +?")
        expectEqual(api.queryItems?.first(where: { $0.name == "password" })?.value, "p/#%&")
        expectEqual(try c.streamURL(id: "123", kind: .movie, extension: "mkv").absoluteString, "https://tv.example:8080/base/movie/a%2Fb%20%2B%3F/p%2F%23%25%26/123.mkv")
    }
    func testRejectsMalformedInputsAndPathInjection() throws {
        for server in ["example.com", "file:///tmp/test", "https://user:pass@example.com"] {
            expectThrows(try Credentials(server: server, username: "a", password: "b"))
        }
        let c = try Credentials(server: "http://example.com", username: "a", password: "b")
        expectThrows(try c.streamURL(id: "../42", kind: .live, extension: "ts"))
        expectThrows(try c.streamURL(id: "42", kind: .movie, extension: "mp4?token=x"))
    }
    func testMixedProviderIDsAndMissingArtwork() throws {
        let data = Data(#"[{"stream_id":123,"name":"News","category_id":4,"stream_icon":null},{"stream_id":"456","name":"Film","category_id":"5","container_extension":"mkv"}]"#.utf8)
        let rows = try JSONDecoder().decode(JSONValue.self, from: data).array!
        let live = MediaItem.parse(rows[0], kind: .live)!
        expectEqual(live.id, "live:123"); expectEqual(live.categoryID, "4"); expectEqual(live.fileExtension, "ts"); expectNil(live.artwork)
        expectEqual(MediaItem.parse(rows[1], kind: .movie)?.fileExtension, "mkv")
    }
    func testAuthenticationLibraryEpisodesAndGuide() async throws {
        let client = try makeClient()
        try await client.authenticate()
        let (categories, movies) = try await client.library(.movie)
        expectEqual(categories.first?.id, "7")
        expectEqual(movies.count, 1, "Duplicate provider IDs must not break SwiftUI identity")
        expectEqual(movies.first?.fileExtension, "mkv")
        let episodes = try await client.episodes(series: MediaItem(streamID: "9", kind: .series, name: "Show"))
        expectEqual(episodes.map(\.streamID), ["101", "102", "201"])
        expectEqual(episodes.first?.season, 1)
        let guide = try await client.guide(for: MediaItem(streamID: "42", kind: .live, name: "News"))
        expectEqual(guide.first?.title, "Morning News")
    }
    func testInvalidLoginAndNonJSONHaveSafeErrors() async throws {
        do { try await makeClient(username: "bad").authenticate(); fail("Expected rejection") }
        catch { expectEqual(error.localizedDescription, ProviderError.unauthorized.localizedDescription) }
        do { try await makeClient(username: "html").authenticate(); fail("Expected invalid response") }
        catch { expectEqual(error.localizedDescription, ProviderError.invalidResponse.localizedDescription); expectFalse(error.localizedDescription.contains("secret")) }
        do { try await makeClient(username: "expired").authenticate(); fail("Expected inactive account") }
        catch { expectEqual(error.localizedDescription, ProviderError.inactive.localizedDescription) }
    }
    func testSubtitlePreferences() throws {
        var style = SubtitleAppearance()
        style.size = 150; style.textColor = 0xFFD700; style.backgroundColor = 0x123456
        style.backgroundOpacity = 50; style.verticalOffset = 120
        let restored = try JSONDecoder().decode(SubtitleAppearance.self, from: JSONEncoder().encode(style))
        expectEqual(restored, style)
        expectEqual(SubtitleAppearance.delayMicroseconds(1.25), 1_250_000)
        expectEqual(SubtitleAppearance.delayMicroseconds(-0.1), -100_000)
        expectEqual(SubtitleAppearance.delayMicroseconds(.infinity), 0)
        style.size = .nan; style.backgroundOpacity = 200; style.verticalOffset = -50; style.textColor = 0xFFFFFFFF
        expectEqual(style.normalized.size, 100)
        expectEqual(style.normalized.backgroundOpacity, 100)
        expectEqual(style.normalized.verticalOffset, 0)
        expectEqual(style.normalized.textColor, 0xFFFFFF)
    }
    private func makeClient(username: String = "user") throws -> XtreamClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return XtreamClient(credentials: try Credentials(server: "https://example.test", username: username, password: "secret"), session: URLSession(configuration: config))
    }
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "User-Agent") == "Luma/0.3", "Provider-facing identity must remain compatible across app releases")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let action = query.first(where: { $0.name == "action" })?.value
        let user = query.first(where: { $0.name == "username" })?.value
        let body: String
        switch action {
        case "get_vod_categories": body = #"[{"category_id":7,"category_name":"Movies"}]"#
        case "get_vod_streams": body = #"[{"stream_id":12,"name":"Film","container_extension":"mkv"},{"stream_id":12,"name":"Duplicate"}]"#
        case "get_series_info": body = #"{"episodes":{"2":[{"id":201,"title":"Third","season":2,"episode_num":1}],"1":[{"id":"102","title":"Second","season":"1","episode_num":"2"},{"id":101,"title":"First","season":1,"episode_num":1}]}}"#
        case "get_short_epg": body = #"{"epg_listings":[{"id":1,"title":"TW9ybmluZyBOZXdz","start_timestamp":"1700000000","stop_timestamp":1700003600}]}"#
        default:
            if user == "bad" { body = #"{"user_info":{"auth":0}}"# }
            else if user == "html" { body = "<html>Not an API</html>" }
            else if user == "expired" { body = #"{"user_info":{"auth":1,"status":"Expired"}}"# }
            else { body = #"{"user_info":{"auth":"1","status":"Active"}}"# }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual). \(message)", file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { precondition(value == nil, "Expected nil", file: file, line: line) }
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false", file: file, line: line) }
private func fail(_ message: String, file: StaticString = #file, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
private func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value(); fail("Expected an error", file: file, line: line) } catch { }
}
