// Production library/player with isolated preferences, local-only provider and generated video.
import AppKit
import SwiftUI
import StreamCore

@main struct ViewingLibraryCheck {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let server = CommandLine.arguments[2]
        let suite = "com.luma.viewing-checks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let credentials = try! Credentials(server: server, username: "fixture", password: "fixture")
        let other = try! Credentials(server: server, username: "other", password: "fixture")
        let film = MediaItem(streamID: "1", kind: .movie, name: "Local H.264 test")
        let series = MediaItem(streamID: "1", kind: .series, name: "Local test series")
        let episode = MediaItem(streamID: "101", kind: .series, name: "Test episode 1", season: 1, episode: 1)
        let store = LibraryStore(restoreSession: false, preferences: preferences)
        store.credentials = credentials
        let account = store.viewingAccountKey
        store.toggleWatchlist(film); store.toggleWatchlist(series)
        let model = PlayerModel(); model.volume = 0
        model.onProgress = { store.recordProgress(title: film, item: film, snapshot: $0, next: nil, account: account) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Luma · Continue watching checks"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 690)
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: film, url: video, client: nil).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(15)
                while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                precondition(predicate(), "Timeout: \(label)"); print("PASS: \(label)")
            }
            await waitFor("first playback") { model.engine.time.intValue > 3200 }
            model.toggle()
            await waitFor("pause") { model.status == "Paused" }
            model.stop()
            let saved = store.viewing.position(for: film)
            precondition(saved > 3 && saved < 6, "Save actual playback position on pause/close")
            let restored = LibraryStore(restoreSession: false, preferences: preferences)
            restored.credentials = credentials
            precondition(restored.viewing.position(for: film) == saved && restored.viewing.watchlist.count == 2)
            restored.credentials = other
            precondition(restored.viewing.progress.isEmpty && restored.viewing.watchlist.isEmpty)
            restored.recordProgress(title: film, item: film, snapshot: .init(seconds: 8, duration: 10, finished: false), next: nil, account: account)
            precondition(restored.viewing.progress.isEmpty, "Reject delayed callbacks from another account")
            restored.credentials = credentials
            precondition(restored.viewing.position(for: film) == saved)
            let resumed = PlayerModel(); resumed.volume = 0
            resumed.prepareResume(at: saved)
            resumed.onProgress = { restored.recordProgress(title: film, item: film, snapshot: $0, next: nil, account: account) }
            window.contentView = NSHostingView(rootView: PlayerScreen(player: resumed, close: { app.terminate(nil) }, item: film, url: video, client: nil).preferredColorScheme(.dark))
            await waitFor("restored playback position") { resumed.engine.time.intValue >= Int32(saved * 1000) && resumed.engine.isPlaying }
            precondition(Double(resumed.engine.time.intValue) / 1000 < saved + 2)
            precondition(restored.viewing.position(for: film) >= saved, "Do not overwrite saved position while opening")
            resumed.toggle()
            await waitFor("resumed pause") { resumed.status == "Paused" }
            resumed.stop()
            precondition(restored.viewing.position(for: film) >= saved)
            print("PASS: persisted Watchlist and history, account isolation, resume at saved position, final progress flush")
            if !CommandLine.arguments.contains("--manual") { preferences.removePersistentDomain(forName: suite); app.terminate(nil); return }
            restored.kind = .series
            restored.recordProgress(title: series, item: episode, snapshot: .init(seconds: 4, duration: 10, finished: false), next: nil, account: account)
            restored.reload(force: true)
            window.contentView = NSHostingView(rootView: LibraryView().environmentObject(restored).preferredColorScheme(.dark).background(Theme.background).foregroundStyle(.white))
            print("READY: production library with persistent resume and Watchlist fixtures; current series episode saved at 00:04")
        }
        app.run()
    }
}
