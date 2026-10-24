import SwiftUI
import StreamCore

struct DetailView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let play: (MediaItem, [MediaItem], @escaping (MediaItem) -> Void) -> Void
    var resumeItemID: String? = nil
    @State private var startedRequestedPlayback = false
    @State private var resumeError: String?
    @State private var episodes: [MediaItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var season: Int = 1
    private var seasons: [Int] { Array(Set(episodes.map { $0.season ?? -1 })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text(item.kind.title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Theme.accent); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Theme.muted) }.buttonStyle(.plain).help("Close details") }
            HStack(alignment: .top, spacing: 26) {
                Artwork(item: item).frame(width: 155, height: 210).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.name).font(.system(size: 28, weight: .semibold)).tracking(-0.8)
                    if let plot = item.plot, !plot.isEmpty { Text(plot).font(.callout).foregroundStyle(Theme.muted).lineLimit(6) }
                    if store.demo { Text("You’re viewing a sample title. Connect your provider to watch your own movies, series, and channels.").font(.callout).foregroundStyle(Theme.muted) }
                    HStack(spacing: 12) {
                        if store.demo { Button("Connect provider") { dismiss(); store.showConnection = true }.buttonStyle(.borderedProminent).tint(Theme.accent) }
                        else if item.kind != .series { Button { play(item, [], { _ in }) } label: { Label(store.viewing.position(for: item) > 0 ? "Resume" : "Watch now", systemImage: "play.fill") }.buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large) }
                        Button { store.toggleFavorite(item) } label: { Image(systemName: store.favorites.contains(item.id) ? "heart.fill" : "heart") }.buttonStyle(.bordered).controlSize(.large).help("Toggle favorite")
                        if item.kind != .live {
                            Button { store.toggleWatchlist(item) } label: { Label("Watchlist", systemImage: store.isWatchlisted(item) ? "bookmark.fill" : "bookmark") }
                                .buttonStyle(.bordered).controlSize(.large).tint(store.isWatchlisted(item) ? Theme.accent : nil)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.kind == .series && !store.demo {
                Divider()
                HStack { Text("Episodes").font(.title3.bold()); Spacer(); if !seasons.isEmpty { Picker("Season", selection: $season) { ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : $0 == -1 ? "Unspecified season" : "Season \($0)").tag($0) } }.frame(width: 170) } }
                if loading { ProgressView("Loading episodes…").frame(maxWidth: .infinity).padding(30) }
                else if let error { VStack(spacing: 10) { Text(error).font(.callout); Button("Try again") { Task { await load() } } }.frame(maxWidth: .infinity) }
                else if episodes.isEmpty { Text("Your provider has not supplied any episodes for this series.").foregroundStyle(Theme.muted) }
                else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(episodes.filter { ($0.season ?? -1) == season }) { episode in
                                Button { play(episode, episodes, { season = $0.season ?? -1 }) } label: {
                                    HStack(spacing: 15) {
                                        Text(String(format: "%02d", episode.episode ?? 0)).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(Theme.muted).frame(width: 30)
                                        VStack(alignment: .leading, spacing: 5) { Text(episode.name).font(.callout).lineLimit(1); if let plot = episode.plot { Text(plot).font(.caption).foregroundStyle(Theme.muted).lineLimit(2) } }
                                        Spacer(); Image(systemName: "play.circle").font(.title2).foregroundStyle(Theme.accent)
                                    }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 270)
                }
            }
        }.padding(30).frame(width: 660).background(Theme.background).foregroundStyle(.white)
        .task {
            guard !store.demo else { return }
            if item.kind == .series { await load() }
            else { await resumeIfRequested() }
        }
        .alert("Couldn’t resume episode", isPresented: Binding(get: { resumeError != nil }, set: { if !$0 { resumeError = nil } })) { Button("OK") { resumeError = nil } } message: { Text(resumeError ?? "") }
    }
    private func load() async {
        guard let catalog = store.seriesCatalog else { return }
        loading = true; error = nil
        do {
            episodes = try await catalog.details(for: item).episodes
            let saved = store.viewing.progress.first { $0.title.id == item.id }?.item
            season = saved?.season.flatMap { seasons.contains($0) ? $0 : nil } ?? seasons.first ?? 1
            await resumeIfRequested()
        }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func resumeIfRequested() async {
        guard !startedRequestedPlayback, let resumeItemID else { return }
        // The sheet must become key first, or its presentation can cover the new player.
        while NSApp.keyWindow?.sheetParent == nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        startedRequestedPlayback = true
        if item.kind != .series { play(item, [], { _ in }); return }
        guard let episode = episodes.first(where: { $0.id == resumeItemID }) else {
            resumeError = "This episode is no longer listed by your provider. Choose another episode from the list."; return
        }
        season = episode.season ?? -1
        play(episode, episodes, { season = $0.season ?? -1 })
    }
}
