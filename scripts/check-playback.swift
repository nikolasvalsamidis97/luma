// Run against the framework embedded in the completed app, not an installed VLC.
import AppKit
import VLCKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let view = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = view
let player = VLCMediaPlayer(options: ["--quiet", "--no-video-title-show"])
player.drawable = view
player.media = VLCMedia(url: (CommandLine.arguments[1].hasPrefix("http") ? URL(string: CommandLine.arguments[1])! : URL(fileURLWithPath: CommandLine.arguments[1])))
player.audio?.volume = 0
player.play()
let deadline = Date().addingTimeInterval(15)
var passed = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    if player.isPlaying && player.time.intValue > 1000 { passed = true; break }
    if player.state == .error { break }
}
player.stop()
if !passed { fputs("FAIL: embedded VLC did not advance playback\n", stderr); exit(1) }
print("PASS: embedded VLC decoded video and advanced playback")
