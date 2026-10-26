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
        let presentation = PlayerPresentation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Luma · Episode and power checks"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: MediaItem(streamID: "fixture", kind: .series, name: "Local playback checks"), url: video, client: nil, presentation: presentation).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            @MainActor func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(15)
                while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                precondition(predicate(), "Timeout: \(label)"); print("PASS: \(label)")
            }
            await waitFor("local playback") { model.engine.time.intValue > 500 }
            // Exercise the production event router directly inside this test process.
            // These events are never posted to the system or another app.
            @MainActor func key(_ code: UInt16, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
            }
            precondition(presentation.handle(key(49)) == nil)
            await waitFor("Space pauses playback") { model.status == "Paused" && model.engine.state == .paused && !model.engine.isPlaying }
            _ = presentation.handle(key(49, repeatKey: true))
            precondition(!model.engine.isPlaying, "Holding Space must not toggle repeatedly")
            presentation.controlsPinned = true
            precondition(presentation.handle(key(49)) != nil, "Popover input must be preserved")
            presentation.controlsPinned = false
            precondition(presentation.handle(key(49, flags: .command)) != nil, "Modified shortcuts must be preserved")
            let input = NSTextView(frame: .zero)
            window.contentView!.addSubview(input); window.makeFirstResponder(input)
            precondition(presentation.handle(key(49)) != nil && presentation.handle(key(123)) != nil, "Text editing must not control playback")
            window.makeFirstResponder(nil); input.removeFromSuperview()
            precondition(presentation.handle(key(124)) == nil)
            precondition(model.position > 0.33 && model.position < 0.45 && !model.engine.isPlaying)
            _ = presentation.handle(key(49))
            await waitFor("Right seeks forward on resume") { model.engine.time.intValue > 10000 && model.engine.time.intValue < 14000 && model.engine.isPlaying }
            _ = presentation.handle(key(49))
            await waitFor("Pause after forward seek") { model.engine.state == .paused }
            _ = presentation.handle(key(123))
            precondition(model.position < 0.14 && !model.engine.isPlaying)
            _ = presentation.handle(key(49))
            await waitFor("Left seeks backward on resume") { model.engine.time.intValue < 5000 && model.engine.isPlaying }
            _ = presentation.handle(key(49))
            await waitFor("Pause after backward seek") { model.engine.state == .paused }
            _ = presentation.handle(key(123))
            precondition(model.position == 0 && !model.engine.isPlaying, "Backward seek clamps at beginning")
            _ = presentation.handle(key(124)); _ = presentation.handle(key(124))
            precondition(abs(model.position - 2.0 / 3.0) < 0.01, "Repeated paused skips accumulate")
            _ = presentation.handle(key(124))
            precondition(model.position < 1 && model.position > 0.95, "Forward seek clamps before end")
            _ = presentation.handle(key(123)); _ = presentation.handle(key(123)); _ = presentation.handle(key(123))
            precondition(model.position == 0 && !model.engine.isPlaying)
            @MainActor func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
            }
            let center = NSPoint(x: 500, y: 350)
            precondition(presentation.handle(mouse(.leftMouseDown, center)) == nil, "Video clicks must reach the player")
            precondition(presentation.handle(mouse(.leftMouseUp, center)) == nil)
            await waitFor("Click video resumes playback at beginning") { model.playing && model.engine.time.intValue < 3000 }
            _ = presentation.handle(mouse(.leftMouseDown, center)); _ = presentation.handle(mouse(.leftMouseUp, center))
            await waitFor("Click video pauses playback") { model.status == "Paused" }
            precondition(presentation.handle(mouse(.leftMouseDown, NSPoint(x: 500, y: 30))) != nil, "Control bar clicks must not toggle the video")
            _ = presentation.handle(mouse(.leftMouseDown, center)); _ = presentation.handle(mouse(.leftMouseUp, center))
            _ = presentation.handle(mouse(.leftMouseDown, center, clicks: 2)); _ = presentation.handle(mouse(.leftMouseUp, center, clicks: 2))
            await waitFor("Double-click enters fullscreen") { presentation.isFullscreen }
            try? await Task.sleep(for: .seconds(1))
            precondition(!model.engine.isPlaying, "Double-click must not also toggle playback")
            presentation.toggleFullscreen()
            await waitFor("Return from fullscreen") { !presentation.isFullscreen }
            _ = presentation.handle(key(49))
            await waitFor("Space resumes playback") { model.playing }
            print("PASS: player-scoped shortcuts, repeat suppression, text/popover exclusions, click-to-pause and bounded seeks")
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
