// Isolated generated media and fake catalogue; never opens Keychain or a provider account.
import AppKit
import SwiftUI
import StreamCore
import VLCKit
import IOKit.pwr_mgt
import ObjectiveC

struct EpisodeFixtureLibrary: View {
    @ObservedObject var store: LibraryStore
    let video: URL
    @State private var details = true
    let series = MediaItem(streamID: "fixture", kind: .series, name: "Local episode navigation test")
    var body: some View {
        VStack(spacing: 20) {
            Text("Library behind episode list").font(.title)
            Button("Open episodes") { details = true }
        }.frame(width: 1000, height: 760)
            .sheet(isPresented: $details) {
                DetailView(item: series, play: { episode, episodes, changed in
                    PlayerWindowController.shared.show(item: episode, url: video, client: nil, episodes: episodes,
                        episodeURL: { _ in video }, episodeChanged: {
                            print("PLAY NEXT: \($0.name)"); changed($0)
                        })
                }).environmentObject(store)
            }
    }
}

@main struct EpisodePlayerCheck {
    @MainActor static func assertions() -> [[String: Any]] {
        var value: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess, let value else { return [] }
        let processes = value.takeRetainedValue() as NSDictionary
        return processes[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
    }
    @MainActor static func displayAssertionCount() -> Int {
        assertions().filter { $0[kIOPMAssertionNameKey as String] as? String == "Luma video playback" && $0[kIOPMAssertionTypeKey as String] as? String == "PreventUserIdleDisplaySleep" }.count
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = PlayerModel(); model.volume = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Luma · Episode and power checks"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: MediaItem(streamID: "fixture", kind: .series, name: "Local playback checks"), url: video, client: nil).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(15)
                while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                precondition(predicate(), "Timeout: \(label)"); print("PASS: \(label)")
            }
            await waitFor("local playback") { model.engine.time.intValue > 500 }
            let selector = NSSelectorFromString("delaySleep")
            let original = class_getMethodImplementation(VLCMediaPlayer.self, selector)
            let replacement = class_getMethodImplementation(type(of: model.engine), selector)
            precondition(original != nil && replacement != original, "Legacy user-activity selector must be overridden")
            precondition(displayAssertionCount() == 1, "Exactly one display-only sleep assertion")
            precondition(!assertions().contains { $0[kIOPMAssertionTypeKey as String] as? String == "UserIsActive" }, "Playback must not declare user activity")
            precondition(!model.nearEnd, "No next prompt at the beginning")
            model.toggle()
            await waitFor("pause releases sleep assertion") { model.status == "Paused" && displayAssertionCount() == 0 }
            model.toggle()
            await waitFor("resume acquires one assertion") { model.playing && displayAssertionCount() == 1 }
            model.seek(0.94)
            await waitFor("near-end prompt") { model.nearEnd }
            await waitFor("end releases assertion") { model.finished && displayAssertionCount() == 0 }
            model.setSubtitleDelay(1.5)
            let previousEngine = model.engineID
            model.playNextItem(video)
            precondition(model.engineID != previousEngine && model.subtitleDelay == 0 && !model.nearEnd)
            await waitFor("next episode starts at beginning") { model.engine.time.intValue > 500 && model.engine.time.intValue < 3000 }
            precondition(displayAssertionCount() == 1)
            model.stop()
            precondition(displayAssertionCount() == 0)
            print("PASS: sleep assertion lifecycle, no synthetic user activity, near-end detection, clean next-episode state")
            if !CommandLine.arguments.contains("--manual") { app.terminate(nil); return }
            let catalog = SeriesCatalog { series in
                let json = #"{"episodes":{"1":[{"id":"101","season":1,"episode_num":1,"title":"First episode"},{"id":"102","season":1,"episode_num":2,"title":"Second episode"}],"2":[{"id":"201","season":2,"episode_num":1,"title":"Next season premiere"}]}}"#
                return try SeriesDetails.parse(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), series: series)
            }
            let store = LibraryStore(restoreSession: false, seriesCatalog: catalog)
            window.contentView = NSHostingView(rootView: EpisodeFixtureLibrary(store: store, video: video).preferredColorScheme(.dark))
            print("READY: manually check Play next, fullscreen, Back to episodes, season preservation")
        }
        app.run()
    }
}
