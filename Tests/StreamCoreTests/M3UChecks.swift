import Foundation
import StreamCore

extension StreamCoreChecks {
    func testM3U() async throws {
        let source = URL(string: "https://example.test/folder/list.m3u?token=private-token")!
        let text = """
        #EXTM3U url-tvg="https://example.test/guide.xml"
        #EXTINF:-1 tvg-id="news" tvg-name="News fallback" tvg-logo="logos/news.png" group-title="News, local",News, local
        live.ts?token=stream-secret
        #EXTINF:-1,Duplicate
        live.ts?token=stream-secret
        #EXTINF:-1 tvg-type="movie" group-title='Films',A film 4K MULTISUB
        /movie/u/p/1.mkv
        #EXTINF:-1 group-title="Drama",The Coast S02E01 - New chapter
        /series/u/p/201.mkv
        #EXTINF:-1 group-title="Drama",The Coast S01E02 - Two
        /series/u/p/102.mkv
        #EXTINF:-1 group-title="Drama",The Coast S01E01 - One
        /series/u/p/101.mkv
        #EXTINF:-1 tvg-type="series",Unnumbered series
        /series/u/p/unknown.mkv
        #EXTINF:-1 tvg-name="Fallback"
        #EXTGRP:Other
        /live/fallback.ts
        #EXTINF:-1,Unsafe
        file:///etc/passwd
        """
        let playlist = try M3UPlaylist.parse("\u{FEFF}" + text.replacingOccurrences(of: "\n", with: "\r\n"), source: source)
        let live = playlist.library(.live), movies = playlist.library(.movie).1, shows = playlist.library(.series).1
        precondition(live.1.count == 2 && live.0.count == 2)
        precondition(live.1[0].name == "News, local" && live.1[1].name == "Fallback")
        precondition(live.1[0].artwork?.absoluteString == "https://example.test/folder/logos/news.png")
        let liveURL = try playlist.streamURL(live.1[0]); precondition(liveURL.absoluteString == "https://example.test/folder/live.ts?token=stream-secret")
        precondition(movies.count == 1 && movies[0].fileExtension == "mkv" && movies[0].traits.multipleSubtitles)
        precondition(shows.count == 2 && shows[0].name == "The Coast")
        let episodes = try playlist.details(for: shows[0])
        precondition(episodes.availability.seasonCount == 2 && episodes.episodes.map(\.episode) == [1,2,1])
        let unknown = try playlist.details(for: shows[1]); precondition(unknown.availability.seasonCount == nil)
        let persisted = String(data: try JSONEncoder().encode(live.1 + movies + shows + episodes.episodes), encoding: .utf8)!
        precondition(!persisted.contains("stream-secret") && !persisted.contains("private-token") && !persisted.contains("/series/u/p"))
        let hls = try M3UPlaylist.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts", source: source)
        precondition(hls.library(.live).1.count == 1 && hls.library(.live).1[0].fileExtension == "m3u8")
        let hlsURL = try hls.streamURL(hls.library(.live).1[0]); precondition(hlsURL == source)
        let plain = try M3UPlaylist.parse("https://example.test/one.ts\nhttps://example.test/two.ts", source: source)
        precondition(plain.library(.live).1.count == 2)
        let explicit = try M3UPlaylist.parse("#EXTM3U\n#EXTINF:-1 tvg-type=movie,Film S01E01\n/one.mp4", source: source)
        precondition(explicit.library(.movie).1.count == 1)
        let again = try M3UPlaylist.parse(text, source: source)
        precondition(again.library(.movie).1[0].id == movies[0].id)
        for invalid in ["<html>Sign in</html>", "#EXTM3U\n#EXTINF:-1,No\nfile:///tmp/movie.mp4", "#EXTM3U"] {
            do { _ = try M3UPlaylist.parse(invalid, source: source); preconditionFailure("Accepted invalid playlist") } catch { }
        }
        for invalid in ["file:///tmp/list.m3u", "https://u:p@example.test/list", "not a link"] {
            do { _ = try M3UPlaylist.url(invalid); preconditionFailure("Accepted invalid source") } catch { }
        }
        do { _ = try playlist.streamURL(MediaItem(streamID: "removed", kind: .movie, name: "Removed")); preconditionFailure("Resolved removed entry") } catch { }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [M3UFixture.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let fetched = try await M3UPlaylist.load(source, session: session)
        let fetchedURL = try fetched.streamURL(fetched.library(.live).1[0]); precondition(fetchedURL.absoluteString == "https://cdn.example.test/redirected/video.ts")
        for mode in ["denied", "large", "html"] {
            do { _ = try await M3UPlaylist.load(URL(string: "https://example.test/\(mode)?secret=hidden")!, session: session); preconditionFailure("Accepted failure") }
            catch { precondition(!error.localizedDescription.contains("hidden") && !error.localizedDescription.contains("https://")) }
        }
        let task = Task { try await M3UPlaylist.load(source, session: session) }; task.cancel()
        do { _ = try await task.value; preconditionFailure("Ignored cancellation") } catch is CancellationError {} catch { preconditionFailure("Wrong cancellation error") }
    }
}
private final class M3UFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "User-Agent") == "Luma/0.3")
        let path = request.url!.path
        let response = HTTPURLResponse(url: URL(string: "https://cdn.example.test/redirected/list.m3u")!, statusCode: path == "/denied" ? 403 : 200, httpVersion: nil,
            headerFields: path == "/large" ? ["Content-Length": "40000000"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((path == "/html" ? "<html>Login</html>" : "#EXTM3U\n#EXTINF:-1,News\nvideo.ts").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
