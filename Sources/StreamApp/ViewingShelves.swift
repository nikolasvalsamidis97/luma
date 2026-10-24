import SwiftUI
import StreamCore

struct ViewingShelves: View {
    @ObservedObject var store: LibraryStore
    let resume: (ViewingProgress) -> Void
    let open: (MediaItem) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            panel("Continue watching", symbol: "play.circle", count: store.continueWatching.count) {
                if store.continueWatching.isEmpty {
                    empty("Your next moment awaits", message: "Start a \(store.kind == .series ? "series" : "movie") and pick up right here.", symbol: "play.circle")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.continueWatching) { entry in
                                Button { resume(entry) } label: {
                                    HStack(spacing: 13) {
                                        Artwork(item: entry.title, compact: true).frame(width: 50, height: 68).clipShape(RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(entry.title.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                            if entry.item.kind == .series {
                                                Text(entry.item.name).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                                            }
                                            Text(entry.timeLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.accent)
                                            ProgressView(value: entry.fraction).tint(Theme.accent).frame(maxWidth: .infinity).accessibilityHidden(true)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                                    }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton).accessibilityLabel("\(entry.timeLabel): \(entry.item.name)")
                                    .contextMenu { Button("Remove from Continue watching") { store.removeProgress(entry.id) } }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            panel("Watchlist", symbol: "bookmark", count: store.watchlist.count) {
                if store.watchlist.isEmpty {
                    empty("Save something for later", message: "Tap a title’s bookmark to add it here.", symbol: "bookmark")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.watchlist) { item in
                                HStack(spacing: 4) {
                                    Button { open(item) } label: {
                                        HStack(spacing: 13) {
                                            Artwork(item: item, compact: true).frame(width: 50, height: 68).clipShape(RoundedRectangle(cornerRadius: 7))
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                                                Text(item.kind == .series ? "Explore episodes" : "Ready when you are").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Open watchlist title: \(item.name)")
                                    Button { store.toggleWatchlist(item) } label: {
                                        Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent).padding(9).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help("Remove from Watchlist").accessibilityLabel("Remove \(item.name) from Watchlist")
                                }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
        }
    }
    private func panel<Content: View>(_ title: String, symbol: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                Spacer(minLength: 4)
                if count > 0 { Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted) }
            }
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(20).frame(maxWidth: .infinity).frame(height: 272)
            .background(LinearGradient(colors: [Color(red: 0.13, green: 0.12, blue: 0.14), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.055)))
    }
    private func empty(_ title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent.opacity(0.65)).padding(.bottom, 4)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12)
    }
}
