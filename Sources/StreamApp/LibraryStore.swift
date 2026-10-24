import SwiftUI
import Security
import CryptoKit
import StreamCore

@MainActor final class LibraryStore: ObservableObject {
    var playbackAllowed: () -> Bool = { true }
    var beforeSourceChange: () -> Void = {}
    @Published private(set) var savedPlaylists = SavedPlaylists()
    @Published private(set) var activePlaylistID: String?
    @Published private(set) var sourceRevision = UUID()
    @Published var showPlaylists = false
    private var currentName = ""
    private var connectionStorageReady = true
    var playlistName: String { savedPlaylists.connections.first { $0.id == activePlaylistID }?.displayName ?? (currentName.isEmpty ? providerName : currentName) }
    @Published var credentials: Credentials? { didSet { if credentials != oldValue { restoreViewing() } } }
    @Published private(set) var playlistURL: URL?
    private var playlist: M3UPlaylist?
    @Published var demo = false
    @Published var kind: LibraryKind = .live
    @Published var items: [MediaItem] = []
    @Published var categories: [StreamCategory] = []
    @Published var category: String? = nil
    @Published var search = ""
    @Published var favoritesOnly = false
    @Published var favorites: Set<String> = []
    @Published private(set) var viewing = ViewingLibrary()
    private let preferences: UserDefaults
    private let connectionStorage: ConnectionStorage
    var viewingAccountKey: String { favoritesKey.replacingOccurrences(of: "favorites.", with: "viewing.v1.") }
    var continueWatching: [ViewingProgress] { viewing.progress.filter { $0.title.kind == kind } }
    var watchlist: [MediaItem] { viewing.watchlist.filter { $0.kind == kind } }
    func isWatchlisted(_ item: MediaItem) -> Bool { viewing.watchlist.contains { $0.id == item.id } }
    func toggleWatchlist(_ item: MediaItem) { viewing.toggleWatchlist(item); saveViewing() }
    func removeProgress(_ id: String) { viewing.removeProgress(id); saveViewing() }
    func recordProgress(title: MediaItem, item: MediaItem, snapshot: PlaybackSnapshot, next: MediaItem?, account: String) {
        guard account == viewingAccountKey else { return }
        viewing.record(title: title, item: item, snapshot: snapshot, next: next)
        saveViewing()
    }
    private func saveViewing() {
        if let data = try? JSONEncoder().encode(viewing) { preferences.set(data, forKey: viewingAccountKey) }
    }
    private func restoreViewing() {
        viewing = preferences.data(forKey: viewingAccountKey).flatMap { try? JSONDecoder().decode(ViewingLibrary.self, from: $0) } ?? ViewingLibrary()
    }
    @Published var loading = false
    @Published var connecting = false
    @Published var error: String?
    @Published var loginError: String?
    @Published var showConnection = false
    @Published private(set) var seriesCatalog: SeriesCatalog?
    @Published private(set) var seriesRevision = UUID()
    private func resetSeriesCatalog() {
        MediaFactsStore.shared.clear()
        if let playlist { seriesCatalog = SeriesCatalog(loader: { try playlist.details(for: $0) }) }
        else { seriesCatalog = client.map { SeriesCatalog(client: $0) } }
        seriesRevision = UUID()
    }
    private var cache: [LibraryKind: ([StreamCategory], [MediaItem])] = [:]
    private var loadTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var generation = UUID()
    var connected: Bool { credentials != nil || playlistURL != nil || demo }
    var providerName: String { playlistURL?.host ?? credentials?.server.host ?? "Your provider" }
    func streamResolver() throws -> (MediaItem) throws -> URL {
        if let playlist { return { try playlist.streamURL($0) } }
        if let credentials { return { try credentials.streamURL(id: $0.streamID, kind: $0.kind, extension: $0.fileExtension) } }
        throw ProviderError.invalidStream
    }
    var client: XtreamClient? { credentials.map { XtreamClient(credentials: $0) } }
    var visibleItems: [MediaItem] {
        items.filter { (category == nil || $0.categoryID == category) && (!favoritesOnly || favorites.contains($0.id)) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }
    private var favoritesKey: String {
        if let playlistURL { return "favorites.m3u." + M3UPlaylist.identifier(playlistURL.absoluteString) }
        guard let c = credentials else { return "favorites.preview" }
        let bytes = Data("\(c.server.absoluteString)|\(c.username)".utf8)
        return "favorites." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    init(restoreSession: Bool = true, seriesCatalog: SeriesCatalog? = nil, preferences: UserDefaults = .standard, connectionStorage: ConnectionStorage = .keychain) {
        self.preferences = preferences
        self.connectionStorage = connectionStorage
        self.seriesCatalog = seriesCatalog
        guard restoreSession else { return }
        do {
            if let saved = try connectionStorage.load() {
                savedPlaylists = saved
                if let active = saved.active {
                    credentials = active.credentials; playlistURL = active.playlistURL; activePlaylistID = active.id
                    currentName = active.displayName
                    if playlistURL != nil { kind = .live }
                    resetSeriesCatalog(); restoreFavorites(); reload()
                }
            }
        } catch { connectionStorageReady = false; loginError = error.localizedDescription }
    }
    func connect(server: String, username: String, password: String, remember: Bool, name: String = "") {
        loginTask?.cancel()
        loginError = nil; connecting = true
        loginTask = Task {
            do {
                let c = try Credentials(server: server, username: username, password: password)
                try await XtreamClient(credentials: c).authenticate()
                try Task.checkCancellation()
                try commitConnection(SavedConnection(credentials: c, playlistURL: nil, name: name), remember: remember)
                generation = UUID(); loadTask?.cancel(); cache.removeAll()
                playlist = nil; playlistURL = nil; credentials = c; demo = false; category = nil; search = ""; items = []; categories = []
                resetSeriesCatalog(); restoreFavorites(); connecting = false; showConnection = false; reload()
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; connecting = false; loginError = error.localizedDescription; if !showConnection && connected { self.error = error.localizedDescription } }
        }
    }
    func connectPlaylist(_ link: String, remember: Bool, name: String = "") {
        loginTask?.cancel(); loginError = nil; connecting = true
        loginTask = Task {
            do {
                let url = try M3UPlaylist.url(link)
                let loaded = try await M3UPlaylist.load(url)
                try Task.checkCancellation()
                try commitConnection(SavedConnection(credentials: nil, playlistURL: url, name: name), remember: remember)
                generation = UUID(); loadTask?.cancel(); cache.removeAll()
                playlistURL = url; credentials = nil; playlist = loaded; demo = false
                kind = .live; category = nil; search = ""; items = []; categories = []
                resetSeriesCatalog(); restoreFavorites(); connecting = false; showConnection = false; reload()
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; connecting = false; loginError = error.localizedDescription; if !showConnection && connected { self.error = error.localizedDescription } }
        }
    }
    private func ensureSavedPlaylistsLoaded() throws {
        if !connectionStorageReady { savedPlaylists = try connectionStorage.load() ?? SavedPlaylists(); connectionStorageReady = true }
    }
    private func commitConnection(_ value: SavedConnection, remember: Bool) throws {
        if !connectionStorageReady {
            if remember { try ensureSavedPlaylistsLoaded() }
            else { beforeSourceChange(); activePlaylistID = nil; currentName = value.displayName; sourceRevision = UUID(); favoritesOnly = false; error = nil; return }
        }
        var next = savedPlaylists
        let active = remember ? next.remember(value) : nil
        if !remember { next.activeID = nil }
        try connectionStorage.save(next)
        beforeSourceChange()
        savedPlaylists = next; activePlaylistID = active; currentName = value.displayName
        sourceRevision = UUID(); favoritesOnly = false; error = nil
    }
    func switchPlaylist(_ id: String) {
        guard id != activePlaylistID || !connected, let saved = savedPlaylists.connections.first(where: { $0.id == id }) else { return }
        if let c = saved.credentials { connect(server: c.server.absoluteString, username: c.username, password: c.password, remember: true, name: saved.name) }
        else if let url = saved.playlistURL { connectPlaylist(url.absoluteString, remember: true, name: saved.name) }
    }
    func renamePlaylist(_ id: String, to name: String) {
        var next = savedPlaylists; next.rename(id, to: name)
        do { try connectionStorage.save(next); savedPlaylists = next; loginError = nil }
        catch { loginError = error.localizedDescription }
    }
    func removePlaylist(_ id: String) {
        var next = savedPlaylists; next.remove(id)
        do {
            try connectionStorage.save(next); savedPlaylists = next
            if activePlaylistID == id { disconnect() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
    }
    func cancelConnection() { loginTask?.cancel(); connecting = false }
    func preview() {
        beforeSourceChange(); activePlaylistID = nil; sourceRevision = UUID(); cancelConnection(); generation = UUID(); playlist = nil; playlistURL = nil; credentials = nil; demo = true; error = nil; loginError = nil
        showConnection = false; cache.removeAll(); resetSeriesCatalog(); restoreFavorites(); reload()
    }
    func signOut() {
        if !connectionStorageReady { disconnect(); return }
        var next = savedPlaylists; next.activeID = nil
        do { try connectionStorage.save(next); savedPlaylists = next }
        catch { self.error = error.localizedDescription; return }
        disconnect()
    }
    private func disconnect() {
        beforeSourceChange(); activePlaylistID = nil; currentName = ""; sourceRevision = UUID()
        cancelConnection(); loadTask?.cancel(); generation = UUID(); playlist = nil; playlistURL = nil; credentials = nil; demo = false
        resetSeriesCatalog(); items = []; categories = []; cache = [:]; search = ""; category = nil; favorites = []; viewing = ViewingLibrary(); error = nil; loading = false; favoritesOnly = false
    }
    func toggleFavorite(_ item: MediaItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }
        preferences.set(Array(favorites), forKey: favoritesKey)
    }
    private func restoreFavorites() {
        favorites = Set(preferences.stringArray(forKey: favoritesKey) ?? [])
        restoreViewing()
    }
    func select(_ kind: LibraryKind) { self.kind = kind; category = nil; search = ""; reload() }
    func reload(force: Bool = false) {
        loadTask?.cancel(); error = nil
        if force { resetSeriesCatalog() }
        if demo { categories = DemoLibrary.categories; items = DemoLibrary.items(kind); loading = false; return }
        guard client != nil || playlistURL != nil else { return }
        let client = client, sourceURL = playlistURL, currentPlaylist = playlist
        let selected = kind, token = generation
        if !force, let saved = cache[selected] { categories = saved.0; items = saved.1; loading = false; return }
        loading = true; items = []; categories = []
        loadTask = Task {
            do {
                let result: ([StreamCategory], [MediaItem])
                if let sourceURL {
                    let loaded: M3UPlaylist
                    if !force, let currentPlaylist { loaded = currentPlaylist }
                    else { loaded = try await M3UPlaylist.load(sourceURL) }
                    try Task.checkCancellation()
                    guard generation == token, kind == selected else { return }
                    playlist = loaded; cache.removeAll(); resetSeriesCatalog()
                    result = loaded.library(selected)
                } else if let client { result = try await client.library(selected) }
                else { return }
                try Task.checkCancellation()
                guard generation == token, kind == selected else { return }
                cache[selected] = result; categories = result.0; items = result.1; loading = false
            } catch is CancellationError { }
            catch { guard generation == token, kind == selected else { return }; self.error = error.localizedDescription; loading = false }
        }
    }
}

struct ConnectionStorage {
    var load: () throws -> SavedPlaylists?
    var save: (SavedPlaylists?) throws -> Void
    static let keychain = ConnectionStorage(load: CredentialVault.loadConnection, save: { value in
        if let value { try CredentialVault.saveConnection(value) } else { try CredentialVault.delete() }
    })
}
enum CredentialVault {
    private static let service = "com.luma.stream.credentials"
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "provider"] }
    static func saveConnection(_ connection: SavedPlaylists) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            try check(SecItemAdd(q as CFDictionary, nil))
        } else { try check(status) }
    }
    static func loadConnection() throws -> SavedPlaylists? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return try SavedPlaylists.decode(data)
    }
    static func delete() throws { let status = SecItemDelete(query as CFDictionary); if status != errSecItemNotFound { try check(status) } }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: "LumaKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "macOS Keychain could not access your saved login. You can connect with Remember login switched off."]) }
    }
}

enum DemoLibrary {
    static let categories = [StreamCategory(id: "1", name: "Discover"), StreamCategory(id: "2", name: "Culture & nature"), StreamCategory(id: "3", name: "Entertainment")]
    static func items(_ kind: LibraryKind) -> [MediaItem] {
        let names: [String]
        switch kind {
        case .live: names = ["World News", "The Nature Channel", "Cinema Club", "Arena Sports", "Culture Collective", "After Hours", "Discovery Lab", "The Food Network"]
        case .movie: names = ["Beyond the Horizon", "The Last Summer", "Into the Wild Blue", "Midnight in Tokyo", "A Different Light", "The Long Way Home", "Northern Lights", "Still Life"]
        case .series: names = ["The Coast", "City Stories", "Uncharted", "Small Hours", "The Observatory", "Wild Earth", "Between Worlds", "Sunday Morning"]
        }
        return names.enumerated().map { MediaItem(streamID: "demo\($0.offset)", kind: kind, name: $0.element, categoryID: String($0.offset % 3 + 1), plot: "A little inspiration for your next watch. Connect your provider to explore your own library.") }
    }
}
