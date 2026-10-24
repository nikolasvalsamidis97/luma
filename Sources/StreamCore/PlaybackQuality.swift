import Foundation

public struct VideoResolution: Hashable, Sendable, Identifiable {
    public let width: Int
    public let height: Int
    public var id: String { "\(width)x\(height)" }
    public var label: String { height == 2160 ? "4K" : "\(height)p" }
    public init(width: Int, height: Int) { self.width = width; self.height = height }
    /// Keep the original master playlist so its alternate audio, captions and authentication remain intact.
    public var vlcOptions: [String] {
        ["--adaptive-logic=highest", "--adaptive-maxwidth=\(width)", "--adaptive-maxheight=\(height)"]
    }
}

public enum HLSQualityDiscovery {
    /// Read only video variants; rendition tracks and iframe-only previews are not qualities.
    public static func resolutions(in manifest: String) -> [VideoResolution] {
        guard manifest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return [] }
        var result = Set<VideoResolution>()
        var pending: VideoResolution?
        for raw in manifest.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = nil
                let attributes = line.dropFirst("#EXT-X-STREAM-INF:".count)
                // Commas inside quoted CODECS / NAME fields must stay inside those fields.
                var fields: [String] = [], field = "", quoted = false
                for character in attributes {
                    if character == "\"" { quoted.toggle() }
                    if character == "," && !quoted { fields.append(field); field = "" }
                    else { field.append(character) }
                }
                fields.append(field)
                for field in fields {
                    let parts = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2, parts[0] == "RESOLUTION" else { continue }
                    let size = parts[1].split(separator: "x")
                    if size.count == 2, let width = Int(size[0]), let height = Int(size[1]),
                       (1...16384).contains(width), (1...16384).contains(height) {
                        pending = VideoResolution(width: width, height: height)
                    }
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                if let pending { result.insert(pending) }
                pending = nil
            }
        }
        return result.sorted { ($0.height, $0.width) < ($1.height, $1.width) }
    }
    public static func supports(_ url: URL) -> Bool {
        ["m3u8", "m3u"].contains(url.pathExtension.lowercased()) ||
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.value?.lowercased() == "m3u8" } == true
    }
    public static func load(_ url: URL) async throws -> [VideoResolution] {
        guard supports(url) else { return [] }
        let limit = 1_048_576
        if url.isFileURL {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limit else { return [] }
            return resolutions(in: try String(contentsOf: url, encoding: .utf8))
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= limit else { return [] }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { return [] }
            data.append(byte)
        }
        return String(data: data, encoding: .utf8).map(resolutions(in:)) ?? []
    }
}
