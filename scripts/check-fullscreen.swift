// Isolated production-player check. Only a generated local 4K HEVC file is opened.
import AppKit
import SwiftUI
import StreamCore
import VLCKit

final class DecoderProbe: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    private let lock = NSLock()
    private var hardware = false
    var usesHardware: Bool { lock.lock(); defer { lock.unlock() }; return hardware }
    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        if message.contains("using video decoder module \"videotoolbox\"") {
            lock.lock(); hardware = true; lock.unlock()
        }
    }
}

@main struct FullscreenCheckApp {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let model = PlayerModel(); model.volume = 0
        let probe = DecoderProbe(); model.engine.libraryInstance.loggers = [probe]
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let presentation = PlayerPresentation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Luma · Fullscreen and 4K checks"; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(rootView: PlayerScreen(player: model, close: { app.terminate(nil) }, item: MediaItem(streamID: "fixture", kind: .movie, name: "Local 4K HEVC · Fullscreen check"), url: url, client: nil, presentation: presentation).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(20)
            while model.engine.time.intValue < 1000, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            precondition(model.engine.videoSize == CGSize(width: 3840, height: 2160), "Decode the real 4K fixture")
            let begin = model.engine.media!.statistics
            let engineID = model.engineID
            try? await Task.sleep(for: .seconds(8))
            let end = model.engine.media!.statistics
            let displayed = end.displayedPictures - begin.displayedPictures
            let lost = end.lostPictures - begin.lostPictures
            print("4K RESULTS: hardware=\(probe.usesHardware), displayed=\(displayed), lost=\(lost), fullscreen=\(presentation.isFullscreen), controls=\(presentation.controlsVisible)")
            precondition(probe.usesHardware, "4K HEVC must use the Apple hardware decoder")
            precondition(displayed > 180, "Playback should sustain near 30fps")
            precondition(lost < 15, "Unexpected 4K frame loss")
            precondition(model.engineID == engineID, "Fullscreen must not recreate the playback engine")
            print("PASS: 4K HEVC hardware decoding, sustained rendering, no engine recreation")
            if !CommandLine.arguments.contains("--manual") { model.stop(); app.terminate(nil) }
        }
        app.run()
    }
}
