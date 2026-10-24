// Isolated visual check of production cards; no Keychain or provider connection.
import AppKit
import SwiftUI
import StreamCore

@main struct BadgeCheckApp {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Luma · Season badge checks"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BadgeCheckView().preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
}

struct BadgeCheckView: View {
    private let revision = UUID()
    private let catalog = SeriesCatalog(refusalBackoff: 0) { item in
        let fixtures = [
            #"{"episodes":{"1":[{"id":1}]}}"#,
            #"{"episodes":{"1":[{"id":1}],"2":[{"id":2}],"3":[]}}"#,
            #"{"episodes":{"0":[{"id":1}]}}"#,
            #"{"episodes":[{"id":1}]}"#,
            #"{"episodes":{}}"#
        ]
        guard let index = Int(item.streamID), index < fixtures.count else { throw ProviderError.http(403) }
        return try SeriesDetails.parse(JSONDecoder().decode(JSONValue.self, from: Data(fixtures[index].utf8)), series: item)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Resolution, subtitles and seasons.").font(.title2.bold())
            Text("Each badge belongs to that provider entry.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                ForEach(0..<6) { index in
                    MediaCard(item: MediaItem(streamID: String(index), kind: .series, name: ["4K · Silo · MULTISUB", "Silo [1080p]", "Silo · MULTI AUDIO", "Silo · MULTI-SUB", "Silo UHD", "Silo"][index]), seriesCatalog: catalog, seriesRevision: revision,
                              favorite: false, demo: false, open: {}, toggleFavorite: {})
                }
            }
        }.padding(28).background(Theme.background).foregroundStyle(.white)
    }
}
