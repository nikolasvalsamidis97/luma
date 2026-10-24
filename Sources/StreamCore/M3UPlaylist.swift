import Foundation
import CryptoKit

/// Stream URLs stay in memory; persisted library items contain only opaque identifiers.
public struct M3UPlaylist: Sendable {
    private var items: [MediaItem] = []
    private var streams: [String: URL] = [:]
    private var episodes: [String: [MediaItem]] = [:]
    private var groups: [String: String] = [:]
    public static func identifier(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func url(_ text: String, relativeTo base: URL? = nil) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { throw M3UError.invalidURL }
        return url
    }
    public func library(_ kind: LibraryKind) -> ([StreamCategory], [MediaItem]) {
        let selected = items.filter { $0.kind == kind }
        let ids = Set(selected.map(\.categoryID))
        return (groups.filter { ids.contains($0.key) }.map { StreamCategory(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, selected)
    }
    public func streamURL(_ item: MediaItem) throws -> URL {
        guard let url = streams[item.streamID] else { throw M3UError.removed }
        return url
    }
    public func details(for item: MediaItem) throws -> SeriesDetails {
        guard let values = episodes[item.streamID] else { throw M3UError.removed }
        return SeriesDetails(episodes: values)
    }
    public static func load(_ source: URL, session suppliedSession: URLSession? = nil) async throws -> Self {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForResource = 60
        let session = suppliedSession ?? URLSession(configuration: config)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        do {
            var request = URLRequest(url: try url(source.absoluteString)); request.timeoutInterval = 30; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Luma/0.3", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw M3UError.invalidPlaylist }
            guard (200..<300).contains(http.statusCode) else { throw M3UError.http(http.statusCode) }
            let limit = 32 * 1024 * 1024
            guard response.expectedContentLength <= limit else { throw M3UError.tooLarge }
            var data = Data(); data.reserveCapacity(min(max(Int(response.expectedContentLength), 0), limit))
            for try await byte in bytes {
                if data.count >= limit { throw M3UError.tooLarge }
                data.append(byte)
                if data.count % 16384 == 0 { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            guard let text = String(data: data, encoding: .utf8) else { throw M3UError.invalidPlaylist }
            return try parse(text, source: response.url ?? source)
        } catch is CancellationError { throw CancellationError() }
        catch let error as M3UError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw M3UError.network }
    }
    public static func parse(_ text: String, source: URL) throws -> Self {
        let base = try url(source.absoluteString)
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = lines.first(where: { !$0.isEmpty }) ?? ""
        let extended = first.uppercased().split(whereSeparator: { $0.isWhitespace }).first == "#EXTM3U"
        // Plain M3U has no metadata header; require absolute HTTP(S) entries to avoid treating HTML as links.
        guard extended || (!first.isEmpty && (try? url(first)) != nil && lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.allSatisfy { (try? url($0)) != nil }) else { throw M3UError.invalidPlaylist }
        var result = Self()
        // HLS is one playable stream, never a library of individual transport segments.
        if lines.contains(where: { $0.hasPrefix("#EXT-X-") }) {
            let id = identifier(base.absoluteString)
            result.items = [MediaItem(streamID: id, kind: .live, name: "Live stream", fileExtension: "m3u8")]
            result.streams[id] = base; return result
        }
        let attributes = try NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))"#)
        let episodic = try NSRegularExpression(pattern: #"(?i)^(.*?)\s*[-–: ]*\bS(\d{1,3})E(\d{1,4})\b"#)
        var metadata: [String: String] = [:], title = "", group = ""
        var seen = Set<String>()
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXTINF:") {
                metadata = [:]; group = ""; title = ""
                var quote: Character?, comma: String.Index?
                for index in line.indices {
                    let char = line[index]
                    if char == "\"" || char == "'" { if quote == char { quote = nil } else if quote == nil { quote = char } }
                    if char == ",", quote == nil { comma = index; break }
                }
                let header = comma.map { String(line[..<$0]) } ?? line
                if let comma { title = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces) }
                let ns = header as NSString
                for match in attributes.matches(in: header, range: NSRange(location: 0, length: ns.length)) {
                    for index in 2...4 where match.range(at: index).location != NSNotFound {
                        metadata[ns.substring(with: match.range(at: 1)).lowercased()] = ns.substring(with: match.range(at: index)); break
                    }
                }
                group = metadata["group-title"] ?? ""
            } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)) }
            else if !line.hasPrefix("#") {
                defer { metadata = [:]; title = ""; group = "" }
                guard let stream = try? url(line, relativeTo: base) else { continue }
                let id = identifier(stream.absoluteString)
                guard seen.insert(id).inserted else { continue }
                let name = title.isEmpty ? (metadata["tvg-name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled channel") : title
                let category = group.isEmpty ? "" : identifier(group)
                if !group.isEmpty { result.groups[category] = group }
                let art = metadata["tvg-logo"].flatMap { try? url($0, relativeTo: base) }
                let type = (metadata["tvg-type"] ?? "").lowercased()
                let path = stream.path.lowercased()
                let ns = name as NSString
                let match = episodic.firstMatch(in: name, range: NSRange(location: 0, length: ns.length))
                let kind: LibraryKind
                switch type {
                case "live": kind = .live
                case "movie", "vod": kind = .movie
                case "series": kind = .series
                default: kind = path.hasPrefix("/series/") || match != nil ? .series : path.hasPrefix("/movie/") ? .movie : .live
                }
                let season = match.flatMap { Int(ns.substring(with: $0.range(at: 2))) }
                let episode = match.flatMap { Int(ns.substring(with: $0.range(at: 3))) }
                let item = MediaItem(streamID: id, kind: kind, name: name, categoryID: category, artwork: art,
                                     fileExtension: stream.pathExtension.isEmpty ? (kind == .live ? "ts" : "mp4") : stream.pathExtension,
                                     season: season, episode: episode)
                result.streams[id] = stream
                if kind == .series {
                    let show = metadata["series-name"] ?? match.map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) } ?? name
                    let seriesID = identifier("series\n\(group)\n\(show)")
                    if result.episodes[seriesID] == nil {
                        result.items.append(MediaItem(streamID: seriesID, kind: .series, name: show.isEmpty ? name : show, categoryID: category, artwork: art))
                    }
                    result.episodes[seriesID, default: []].append(item)
                } else { result.items.append(item) }
            }
        }
        guard !result.items.isEmpty else { throw M3UError.invalidPlaylist }
        for key in result.episodes.keys {
            result.episodes[key]?.sort { ($0.season ?? Int.max, $0.episode ?? Int.max, $0.name) < ($1.season ?? Int.max, $1.episode ?? Int.max, $1.name) }
        }
        return result
    }
}
public enum M3UError: LocalizedError {
    case invalidURL, invalidPlaylist, tooLarge, network, removed, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid HTTP or HTTPS playlist link."
        case .invalidPlaylist: return "This link did not return a supported M3U playlist with playable HTTP or HTTPS entries."
        case .tooLarge: return "This playlist exceeds the 32 MB limit."
        case .network: return "Could not download the playlist. Check your connection and try again."
        case .removed: return "This title is no longer in the playlist. Refresh your library."
        case .http(let code): return "The playlist provider returned HTTP \(code). Check your link or try again later."
        }
    }
}
