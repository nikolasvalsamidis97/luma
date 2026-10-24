import AppKit
import SwiftUI
import StreamCore

@main struct M3ULibraryCheck {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let base = CommandLine.arguments[1]
        let suite = "com.luma.m3u-checks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        var saved: SavedPlaylists?
        var rejectSave = false
        let storage = ConnectionStorage(load: { saved }, save: { if rejectSave { throw M3UError.network }; saved = $0 })
        let store = LibraryStore(restoreSession: false, preferences: preferences, connectionStorage: storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Luma · M3U checks"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LibraryView().environmentObject(store).preferredColorScheme(.dark).background(Theme.background).foregroundStyle(.white))
        window.center(); window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(20)
                while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                precondition(predicate(), "Timeout: \(label)"); print("PASS: \(label)")
            }
            do {
                store.connectPlaylist(base + "/start?token=private", remember: true)
                await waitFor("M3U connection and redirected catalog") { !store.connecting && !store.loading && store.connected }
                precondition(store.loginError == nil && store.items.count == 1 && saved?.active?.playlistURL != nil && store.credentials == nil)
                store.select(.movie)
                await waitFor("M3U movie library") { !store.loading && store.items.count == 1 }
                let film = store.items[0], account = store.viewingAccountKey
                store.toggleWatchlist(film)
                let resolver = try store.streamResolver()
                let url = try resolver(film)
                precondition(url.path == "/folder/video.mp4", "Relative playback must use redirect destination")
                let model = PlayerModel(); model.volume = 0
                model.onProgress = { store.recordProgress(title: film, item: film, snapshot: $0, next: nil, account: account) }
                window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: {}, item: film, url: url, client: nil).preferredColorScheme(.dark))
                await waitFor("M3U HTTP video decoded by bundled VLC") { model.engine.isPlaying && model.engine.time.intValue > 3200 }
                model.stop()
                let position = store.viewing.position(for: film)
                precondition(position > 3)
                let restored = LibraryStore(preferences: preferences, connectionStorage: storage)
                await waitFor("saved M3U source restores") { !restored.loading && restored.items.count == 1 }
                precondition(restored.viewing.position(for: film) == position && restored.viewing.watchlist.count == 1)
                let resumed = PlayerModel(); resumed.volume = 0; resumed.prepareResume(at: position)
                window.contentView = NSHostingView(rootView: PlayerScreen(player: resumed, close: {}, item: film, url: try restored.streamResolver()(film), client: nil).preferredColorScheme(.dark))
                await waitFor("M3U resumes at saved position") { resumed.engine.isPlaying && resumed.engine.time.intValue >= Int32(position * 1000) }
                resumed.stop()
                store.select(.series)
                await waitFor("M3U series library") { !store.loading && store.items.count == 1 }
                let details = try await store.seriesCatalog!.details(for: store.items[0])
                precondition(details.availability.seasonCount == 2 && details.episodes.count == 2)
                _ = try store.streamResolver()(details.episodes[1])
                store.connectPlaylist(base + "/fail", remember: true)
                await waitFor("failed playlist keeps previous source") { !store.connecting && store.loginError != nil }
                precondition(store.viewingAccountKey == account && saved?.active?.playlistURL?.path == "/start")
                store.connectPlaylist(base + "/other", remember: false)
                await waitFor("M3U source switch") { !store.connecting && !store.loading && store.playlistURL?.path == "/other" }
                precondition(saved?.active == nil && saved?.connections.count == 1 && store.viewing.progress.isEmpty && store.viewing.watchlist.isEmpty)
                store.recordProgress(title: film, item: film, snapshot: .init(seconds: 4, duration: 10, finished: false), next: nil, account: account)
                precondition(store.viewing.progress.isEmpty)
                store.connectPlaylist(base + "/start?token=private", remember: true)
                await waitFor("original playlist history restored") { !store.connecting && !store.loading && store.viewingAccountKey == account }
                precondition(store.viewing.watchlist.count == 1 && store.viewing.position(for: film) == position)
                _ = try await URLSession.shared.data(from: URL(string: base + "/advance")!)
                store.reload(force: true)
                await waitFor("M3U refresh") { !store.loading }
                do { _ = try store.streamResolver()(film); preconditionFailure("Removed item remained playable") } catch {}
                store.select(.movie); await waitFor("refresh clears other section caches") { !store.loading }
                precondition(store.items.isEmpty && store.viewing.watchlist.count == 1)
                let legacy = try Credentials(server: base, username: "fixture", password: "fixture")
                let migrated = try SavedPlaylists.decode(JSONEncoder().encode(legacy)); precondition(migrated.active?.credentials == legacy)
                store.connect(server: base, username: "fixture", password: "fixture", remember: true)
                await waitFor("Xtream connection after M3U") { !store.connecting && store.credentials != nil }
                precondition(store.playlistURL == nil && saved?.active?.credentials == legacy && saved?.active?.playlistURL == nil)
                store.signOut(); precondition(saved?.active == nil && saved?.connections.count == 2 && !store.connected)
                store.connect(server: base, username: "fixture", password: "fixture", remember: true, name: "Home TV")
                await waitFor("first named Xtream playlist") { !store.connecting && !store.loading && store.credentials?.username == "fixture" }
                let firstID = store.activePlaylistID!, firstAccount = store.viewingAccountKey
                let firstFilm = store.items[0]
                store.toggleFavorite(firstFilm); store.toggleWatchlist(firstFilm)
                store.recordProgress(title: firstFilm, item: firstFilm, snapshot: .init(seconds: 4, duration: 20, finished: false), next: nil, account: firstAccount)
                var closedSources = 0
                store.beforeSourceChange = { closedSources += 1 }
                store.connect(server: base, username: "other", password: "fixture", remember: true, name: "Sports")
                await waitFor("second saved Xtream playlist") { !store.connecting && !store.loading && store.credentials?.username == "other" }
                let secondID = store.activePlaylistID!, secondAccount = store.viewingAccountKey
                precondition(saved?.connections.count == 3 && firstID != secondID && closedSources == 1)
                precondition(store.viewing.progress.isEmpty && store.viewing.watchlist.isEmpty && store.favorites.isEmpty)
                let secondFilm = store.items[0]
                precondition(secondFilm.id == firstFilm.id)
                store.recordProgress(title: firstFilm, item: firstFilm, snapshot: .init(seconds: 15, duration: 20, finished: false), next: nil, account: firstAccount)
                precondition(store.viewing.progress.isEmpty)
                store.recordProgress(title: secondFilm, item: secondFilm, snapshot: .init(seconds: 8, duration: 20, finished: false), next: nil, account: secondAccount)
                store.switchPlaylist(firstID)
                await waitFor("switch back restores first playlist") { !store.connecting && !store.loading && store.activePlaylistID == firstID }
                precondition(store.viewing.position(for: firstFilm) == 4 && store.favorites.contains(firstFilm.id) && store.viewing.watchlist.count == 1)
                store.renamePlaylist(secondID, to: "Sports TV")
                precondition(store.playlistName == "Home TV" && saved?.connections.first(where: { $0.id == secondID })?.name == "Sports TV")
                store.connect(server: base, username: "fixture", password: "rotated", remember: true)
                await waitFor("credential update preserves playlist identity") { !store.connecting && !store.loading && store.credentials?.password == "rotated" }
                precondition(store.activePlaylistID == firstID && saved?.connections.count == 3 && store.playlistName == "Home TV")
                if CommandLine.arguments.contains("--screenshots") {
                    @MainActor func capture<V: View>(_ view: V, name: String) async {
                        window.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark).tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background))
                        try? await Task.sleep(for: .milliseconds(400))
                        let content = window.contentView!; content.layoutSubtreeIfNeeded()
                        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/luma-" + name + ".png"))
                    }
                    await capture(LibraryView().environmentObject(store), name: "playlist-library")
                    await capture(PlaylistManager().environmentObject(store), name: "playlist-manager")
                    await capture(ConnectionForm(isSheet: true).environmentObject(store).frame(width: 480).padding(36), name: "playlist-add")
                    print("PASS: rendered playlist switcher, management and connection views")
                }
                let beforeFailure = closedSources
                store.connect(server: base, username: "bad", password: "fixture", remember: true)
                await waitFor("rejected provider preserves current playlist") { !store.connecting && store.loginError != nil }
                precondition(store.activePlaylistID == firstID && saved?.connections.count == 3 && closedSources == beforeFailure)
                rejectSave = true; store.switchPlaylist(secondID)
                await waitFor("vault failure preserves current playlist") { !store.connecting && store.loginError != nil }
                precondition(store.activePlaylistID == firstID && saved?.activeID == firstID && closedSources == beforeFailure)
                rejectSave = false
                let afterRestart = LibraryStore(preferences: preferences, connectionStorage: storage)
                await waitFor("restart restores selected playlist") { !afterRestart.loading }
                precondition(afterRestart.activePlaylistID == firstID && afterRestart.savedPlaylists.connections.count == 3 && afterRestart.viewing.position(for: firstFilm) == 4)
                store.signOut()
                precondition(!store.connected && saved?.activeID == nil && saved?.connections.count == 3)
                let disconnected = LibraryStore(preferences: preferences, connectionStorage: storage)
                precondition(!disconnected.connected && disconnected.savedPlaylists.connections.count == 3)
                store.switchPlaylist(secondID)
                await waitFor("open saved playlist after disconnect") { !store.connecting && !store.loading && store.activePlaylistID == secondID }
                precondition(store.viewing.position(for: secondFilm) == 8 && store.playlistName == "Sports TV")
                store.removePlaylist(firstID)
                precondition(store.activePlaylistID == secondID && saved?.connections.count == 2)
                store.removePlaylist(secondID)
                precondition(!store.connected && saved?.connections.count == 1 && saved?.activeID == nil)
                print("PASS: multiple Xtream providers, identical-ID history isolation, safe failures, rename/remove, restart and disconnect persistence")
                preferences.removePersistentDomain(forName: suite)
                print("PASS: M3U playback/resume, series, source persistence/isolation, refresh/removals, failure recovery, legacy login migration and Xtream switching")
            } catch { preconditionFailure("M3U integration check failed: \(error.localizedDescription)") }
            app.terminate(nil)
        }
        app.run()
    }
}
