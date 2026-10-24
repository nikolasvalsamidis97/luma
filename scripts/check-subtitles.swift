// Developer integration harness, compiled with the production Player and subtitle views.
// This uses its own app domain and local media; never the user's provider account.
import AppKit
import SwiftUI
import StreamCore
import VLCKit

@main struct SubtitleCheckApp {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        UserDefaults.standard.removeObject(forKey: "subtitle.appearance")
        let model = PlayerModel()
        let video = URL(fileURLWithPath: CommandLine.arguments[1])
        let subtitles = URL(fileURLWithPath: CommandLine.arguments[2])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Luma · Subtitle checks"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: MediaItem(streamID: "fixture", kind: .movie, name: "Subtitle appearance test"), url: video, client: nil).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            @MainActor func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(12)
                while !predicate(), Date() < end { try? await Task.sleep(nanoseconds: 100_000_000) }
                if !predicate() { print("TIMEOUT \(label): state=\(model.engine.state.rawValue) playing=\(model.engine.isPlaying) status=\(model.status) time=\(model.engine.time.intValue) tracks=\(model.subtitleTracks) selected=\(model.selectedSubtitle) error=\(model.subtitleError ?? "none")") }
                precondition(predicate(), "Subtitle integration condition timed out: \(label)")
                print("PASS \(label)")
            }
            await waitFor("initial playback") { model.engine.isPlaying && model.engine.time.intValue > 500 }
            model.loadSubtitleFile(subtitles)
            await waitFor("imported track") { !model.subtitleTracks.isEmpty }
            model.selectSubtitle(model.subtitleTracks[0].id)
            model.setSubtitleDelay(-0.3)
            precondition(model.engine.currentVideoSubTitleDelay == -300_000)
            model.setSubtitleDelay(0.2)
            precondition(model.engine.currentVideoSubTitleDelay == 200_000)
            model.setSubtitleDelay(0)
            model.selectSubtitle(-1)
            precondition(model.engine.currentVideoSubTitleIndex == -1)
            model.selectSubtitle(model.subtitleTracks[0].id)
            model.toggle()
            await waitFor("pause") { !model.engine.isPlaying }
            let pausedTime = model.engine.time.intValue
            var style = SubtitleAppearance()
            style.size = 150; style.textColor = 0xFFFF00; style.backgroundColor = 0x0022AA
            style.backgroundOpacity = 80; style.verticalOffset = 100
            model.applySubtitleAppearance(style)
            await waitFor("restored subtitles and pause") { !model.subtitleTracks.isEmpty && !model.engine.isPlaying && model.status == "Paused" }
            precondition(abs(model.engine.time.intValue - pausedTime) < 1200, "Style changes must preserve the playback position")
            precondition(model.selectedSubtitle >= 0, "Selected subtitle should survive a style reload")
            precondition(PlayerModel().subtitleAppearance == style, "Style preferences must persist")
            print("PASS: subtitle import, track on/off, signed delay, style reload, paused position, persisted preferences")
            if !CommandLine.arguments.contains("--manual") { model.stop(); app.terminate(nil) }
        }
        app.run()
    }
}
