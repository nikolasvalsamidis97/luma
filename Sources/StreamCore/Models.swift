import Foundation

public enum LibraryKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case live, movie, series
    public var id: String { rawValue }
    public var title: String { switch self { case .live: "Live TV"; case .movie: "Movies"; case .series: "Series" } }
    public var symbol: String { switch self { case .live: "tv"; case .movie: "film"; case .series: "rectangle.stack" } }
    public var action: String { switch self { case .live: "get_live_streams"; case .movie: "get_vod_streams"; case .series: "get_series" } }
    public var categoryAction: String { switch self { case .live: "get_live_categories"; case .movie: "get_vod_categories"; case .series: "get_series_categories" } }
}

public struct Credentials: Codable, Equatable, Sendable {
    public let server: URL
    public let username: String
    public let password: String
    public init(server: String, username: String, password: String) throws {
        let input = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: input), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { throw ProviderError.invalidServer }
        c.query = nil; c.fragment = nil
        if c.path.hasSuffix("/player_api.php") { c.path = String(c.path.dropLast("/player_api.php".count)) }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url else { throw ProviderError.invalidServer }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { throw ProviderError.missingCredentials }
        self.server = url; self.username = user; self.password = password
    }
    public func apiURL(action: String? = nil, parameters: [String: String] = [:]) -> URL {
        var c = URLComponents(url: server.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { c.queryItems!.append(URLQueryItem(name: "action", value: action)) }
        c.queryItems! += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // PHP query parsing treats a literal plus as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }
    public func streamURL(id: String, kind: LibraryKind, extension ext: String) throws -> URL {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(safe.contains), !ext.isEmpty,
              ext.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { throw ProviderError.invalidStream }
        // Encode every credential as one path segment, including embedded slashes and percent signs.
        let segment = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let user = username.addingPercentEncoding(withAllowedCharacters: segment)!
        let pass = password.addingPercentEncoding(withAllowedCharacters: segment)!
        var c = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath += "/\(kind.rawValue)/\(user)/\(pass)/\(id).\(ext)"
        return c.url!
    }
}

public enum ProviderError: LocalizedError {
    case invalidServer, missingCredentials, unauthorized, inactive, invalidResponse, invalidStream, network, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a server address beginning with http:// or https://, including the port if your provider uses one."
        case .missingCredentials: "Enter your provider username and password."
        case .unauthorized: "Your provider did not accept these credentials. Check your username and password."
        case .inactive: "Your provider reports that this account is not active."
        case .invalidResponse: "The server returned an unexpected response. Check the server address and try again."
        case .invalidStream: "This item does not have a valid stream address."
        case .network: "Could not reach your provider. Check your connection and server address, then try again."
        case .http(let code): "Your provider returned HTTP \(code). Please try again later."
        }
    }
}

// Xtream providers commonly mix string and numeric IDs, ratings, and flags.
public enum JSONValue: Decodable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public subscript(key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    public var string: String? {
        switch self { case .string(let v): v; case .number(let v): v.rounded() == v ? String(format: "%.0f", v) : String(v); case .bool(let v): v ? "1" : "0"; default: nil }
    }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

public struct StreamCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public let streamID: String
    public let kind: LibraryKind
    public let name: String
    public let categoryID: String
    public let artwork: URL?
    public let fileExtension: String
    public let rating: String?
    public let plot: String?
    public let season: Int?
    public let episode: Int?
    public let traits: MediaTraits
    public var id: String { "\(kind.rawValue):\(streamID)" }
    public init(streamID: String, kind: LibraryKind, name: String, categoryID: String = "", artwork: URL? = nil, fileExtension: String = "mp4", rating: String? = nil, plot: String? = nil, season: Int? = nil, episode: Int? = nil, traits: MediaTraits? = nil) {
        self.streamID = streamID; self.kind = kind; self.name = name; self.categoryID = categoryID; self.artwork = artwork; self.fileExtension = fileExtension; self.rating = rating; self.plot = plot; self.season = season; self.episode = episode
        self.traits = traits ?? MediaTraits.from(name: name)
    }
    public static func parse(_ j: JSONValue, kind: LibraryKind) -> MediaItem? {
        guard let id = j[kind == .series ? "series_id" : "stream_id"].string, let name = j["name"].string else { return nil }
        let art = j[kind == .series ? "cover" : "stream_icon"].string.flatMap(URL.init(string:))
        return MediaItem(streamID: id, kind: kind, name: name, categoryID: j["category_id"].string ?? "", artwork: art,
                         fileExtension: j["container_extension"].string ?? (kind == .live ? "ts" : "mp4"), rating: j["rating"].string, plot: j["plot"].string, traits: MediaTraits.from(name: name, metadata: j))
    }
}
public struct GuideEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public var isNow: Bool { start <= Date() && end > Date() }
}
