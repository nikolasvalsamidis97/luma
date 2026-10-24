import Foundation

/// Encode only into the platform credential vault, never preferences or a library cache.
public struct SavedConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var credentials: Credentials?
    public var playlistURL: URL?
    public var accountKey: String {
        if let playlistURL { return "m3u." + M3UPlaylist.identifier(playlistURL.absoluteString) }
        guard let credentials else { return "invalid" }
        return M3UPlaylist.identifier("\(credentials.server.absoluteString)|\(credentials.username)")
    }
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (playlistURL?.host ?? credentials?.server.host ?? "Playlist") : trimmed
    }
    public var sourceType: String { playlistURL == nil ? "Xtream Codes" : "M3U" }
    public init(credentials: Credentials?, playlistURL: URL?, name: String = "", id: String = UUID().uuidString) {
        self.id = id; self.name = name; self.credentials = credentials; self.playlistURL = playlistURL
    }
    private enum CodingKeys: String, CodingKey { case id, name, credentials, playlistURL }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        credentials = try c.decodeIfPresent(Credentials.self, forKey: .credentials)
        playlistURL = try c.decodeIfPresent(URL.self, forKey: .playlistURL)
        guard (credentials != nil) != (playlistURL != nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid saved playlist"))
        }
    }
}
public struct SavedPlaylists: Codable, Equatable, Sendable {
    public var connections: [SavedConnection] = []
    public var activeID: String?
    public init() {}
    public var active: SavedConnection? { connections.first { $0.id == activeID } }
    /// Re-entering an account updates its credentials without duplicating its library/history.
    @discardableResult public mutating func remember(_ connection: SavedConnection) -> String {
        var value = connection
        if let index = connections.firstIndex(where: { $0.accountKey == value.accountKey }) {
            value.id = connections[index].id
            if value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.name = connections[index].name }
            connections[index] = value
        } else { connections.append(value) }
        activeID = value.id; return value.id
    }
    public mutating func remove(_ id: String) {
        connections.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }
    public mutating func rename(_ id: String, to name: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let collection = try? decoder.decode(Self.self, from: data) { return collection }
        var collection = Self()
        if let old = try? decoder.decode(Credentials.self, from: data) {
            collection.remember(SavedConnection(credentials: old, playlistURL: nil))
        } else { collection.remember(try decoder.decode(SavedConnection.self, from: data)) }
        return collection
    }
}
