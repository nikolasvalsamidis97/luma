// Production player against Apple's public HLS developer fixture. No provider account used.
import AppKit
import SwiftUI
import StreamCore
import VLCKit

@main struct MediaControlsCheckApp {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        UserDefaults.standard.removeObject(forKey: "subtitle.appearance")
        let model = PlayerModel(); model.volume = 0
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Luma · Audio and quality checks"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: MediaItem(streamID: "fixture", kind: .movie, name: "Audio & quality · Apple test stream"), url: url, client: nil).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            @MainActor func waitFor(_ label: String, _ predicate: () -> Bool) async {
                let end = Date().addingTimeInterval(25)
                while !predicate(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
                if !predicate() { print("TIMEOUT \(label): \(model.status), size=\(model.engine.videoSize), audio=\(model.audioTracks), time=\(model.engine.time.intValue)") }
                precondition(predicate(), label); print("PASS \(label)")
            }
            await waitFor("HLS playback and quality discovery") { model.engine.time.intValue > 1000 && model.qualities.count >= 3 && !model.audioTracks.isEmpty }
            print("Available audio: \(model.audioTracks), qualities: \(model.qualities.map(\.label))")
            for track in model.audioTracks {
                model.selectAudio(track.id)
                await waitFor("audio track \(track.id)") { model.engine.currentAudioTrackIndex == track.id }
            }
            let chosenAudio = model.audioTracks.first { $0.id == model.selectedAudio }!
            if let sub = model.subtitleTracks.first { model.selectSubtitle(sub.id) }
            model.setSubtitleDelay(0.3)
            model.seek(0.12)
            await waitFor("seek before quality change") { model.engine.time.intValue > 10_000 }
            model.toggle()
            await waitFor("paused") { model.status == "Paused" }
            let pausedTime = model.engine.time.intValue
            let low = model.qualities.first { $0.resolution.height == 360 }!
            model.selectQuality(low.id)
            await waitFor("360p quality and paused resume") { model.engine.videoSize.height == 360 && model.status == "Paused" && !model.engine.isPlaying }
            print("Resume position before=\(pausedTime), after=\(model.engine.time.intValue)")
            precondition(abs(model.engine.time.intValue - pausedTime) < 2000, "Quality change lost position")
            precondition(model.audioTracks.first { $0.id == model.selectedAudio }?.name == chosenAudio.name, "Quality change lost audio selection")
            precondition(model.engine.currentVideoSubTitleDelay == 300_000, "Quality change lost subtitle delay")
            model.toggle()
            let medium = model.qualities.first { $0.resolution.height == 720 }!
            model.selectQuality(medium.id)
            await waitFor("720p playback") { model.engine.videoSize.height == 720 && model.playing && model.engine.time.intValue > 1000 }
            model.selectQuality("auto")
            await waitFor("return to Auto") { model.playing && model.selectedQualityID == "auto" && model.engine.time.intValue > 1000 }
            print("PASS: actual decoded HLS resolutions, audio selection, preserved position/pause/subtitle delay, Auto")
            if !CommandLine.arguments.contains("--manual") { model.stop(); app.terminate(nil) }
        }
        app.run()
    }
}
