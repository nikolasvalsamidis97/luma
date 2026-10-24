import SwiftUI
import StreamCore

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    private struct Selection: Identifiable {
        let item: MediaItem
        var resumeItemID: String? = nil
        var id: String { item.id }
    }
    @State private var selected: Selection?
    @State private var playError: String?
    @State private var sortByName = false
    private var displayed: [MediaItem] { sortByName ? store.visibleItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : store.visibleItems }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                topbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if store.kind == .live { hero }
                        else { ViewingShelves(store: store, resume: { selected = Selection(item: $0.title, resumeItemID: $0.item.id) }, open: { selected = Selection(item: $0) }) }
                        catalogue
                    }.padding(30)
                }
            }.frame(maxWidth: .infinity)
        }
        .onChange(of: store.sourceRevision) { _, _ in selected = nil; playError = nil }
        .sheet(item: $selected) { selection in
            let item = selection.item
            DetailView(item: item, play: { episode, episodes, changed in
                play(episode, title: item, episodes: episodes, episodeChanged: changed)
            }, resumeItemID: selection.resumeItemID).environmentObject(store)
        }
        .alert("Couldn’t open stream", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) { Button("OK") { playError = nil } } message: { Text(playError ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Brand().padding(.top, 38).padding(.bottom, 40).padding(.leading, 22)
            Text("YOUR LIBRARY").font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.bottom, 13)
            ForEach(LibraryKind.allCases) { kind in
                Button { store.favoritesOnly = false; store.select(kind) } label: {
                    HStack(spacing: 13) { Image(systemName: kind.symbol).frame(width: 20); Text(kind.title); Spacer(); if store.kind == kind && !store.favoritesOnly { Circle().fill(Theme.accent).frame(width: 5, height: 5) } }
                        .font(.system(size: 14, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 13)
                        .foregroundStyle(store.kind == kind && !store.favoritesOnly ? .white : Theme.muted)
                        .background(store.kind == kind && !store.favoritesOnly ? .white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 3)
            }
            Button { store.favoritesOnly.toggle(); store.category = nil } label: {
                HStack(spacing: 13) { Image(systemName: "heart").frame(width: 20); Text("Favorites"); Spacer() }.font(.system(size: 14, weight: .medium)).foregroundStyle(store.favoritesOnly ? Theme.accent : Theme.muted).padding(15)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 12)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(24)
            Text("CATEGORIES").font(.system(size: 10, weight: .bold)).tracking(1.8).foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    categoryButton("All \(store.kind == .live ? "channels" : store.kind.title.lowercased())", id: nil)
                    ForEach(store.categories) { category in categoryButton(category.name, id: category.id) }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 14) {
                if store.demo {
                    Label("Preview mode", systemImage: "sparkles").font(.caption).foregroundStyle(Theme.accent)
                    Button("Connect your provider") { store.showConnection = true }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                } else {
                    Menu {
                        ForEach(store.savedPlaylists.connections) { playlist in
                            Button { store.switchPlaylist(playlist.id) } label: {
                                if store.activePlaylistID == playlist.id { Label(playlist.displayName, systemImage: "checkmark") }
                                else { Text(playlist.displayName) }
                            }
                        }
                        Divider()
                        Button("Add playlist…") { store.loginError = nil; store.showConnection = true }
                        Button("Manage playlists…") { store.loginError = nil; store.showPlaylists = true }
                    } label: {
                        HStack(spacing: 9) { Circle().fill(Color.green).frame(width: 6, height: 6); Text(store.playlistName).lineLimit(1); Spacer(); Image(systemName: "chevron.up.chevron.down") }
                            .font(.caption).foregroundStyle(.white).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).disabled(store.connecting)
                    if store.connecting { ProgressView("Switching playlist…").controlSize(.small).font(.caption) }
                    Button { store.loginError = nil; store.showConnection = true } label: { Label("Add playlist", systemImage: "plus") }.buttonStyle(.plain).font(.caption).disabled(store.connecting)
                }
                Button(store.demo ? "Exit preview" : "Disconnect") { PlayerWindowController.shared.close(); store.signOut() }.font(.caption).buttonStyle(.plain).foregroundStyle(Theme.muted)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.12))
        }.frame(width: 216).background(Theme.sidebar)
    }
    private func categoryButton(_ name: String, id: String?) -> some View {
        Button { store.category = id } label: {
            HStack { Text(name).lineLimit(1); Spacer(); if store.category == id { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) } }.font(.system(size: 12)).foregroundStyle(store.category == id ? .white : Theme.muted).padding(.horizontal, 13).padding(.vertical, 9)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var topbar: some View {
        HStack(spacing: 20) {
            Text(store.kind.title).font(.system(size: 14, weight: .semibold))
            if store.demo { Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.accent).padding(.horizontal, 8).padding(.vertical, 4).background(Theme.accent.opacity(0.1), in: Capsule()) }
            Spacer()
            HStack(spacing: 9) { Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted); TextField("Search \(store.kind.title.lowercased())", text: $store.search).textFieldStyle(.plain); if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) } }.font(.system(size: 12)).padding(10).frame(width: 250).background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
            Button { store.reload(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Refresh library (⌘R)").disabled(store.loading)
        }.padding(.horizontal, 30).padding(.top, 27).padding(.bottom, 18).overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }
    private var hero: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 7) { Circle().fill(Theme.accent).frame(width: 5, height: 5); Text(store.kind == .live ? "THE WORLD, IN REAL TIME" : store.kind == .movie ? "MAKE A NIGHT OF IT" : "FIND YOUR NEXT CHAPTER").tracking(2) }.font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                Text(store.kind == .live ? "Tune into\nsomething good." : store.kind == .movie ? "Big stories.\nYour screen." : "One more\nepisode.").font(.system(size: 39, weight: .semibold)).tracking(-1.4).lineSpacing(-2)
                Text(store.kind == .live ? "Your favorite channels, all in one place." : store.kind == .movie ? "A world of cinema. Ready when you are." : "New discoveries and familiar favorites.").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
                if store.demo { Text("Sample library • Connect your provider to watch").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 5) }
                else { Text("\(store.items.count.formatted()) \(store.kind == .live ? "channels" : "titles") in your library").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 5) }
            }.padding(30)
            Spacer(minLength: 0)
            ZStack {
                ForEach(0..<4) { i in RoundedRectangle(cornerRadius: 28).stroke(Theme.accent.opacity(Double(5-i) * 0.05), lineWidth: 1).frame(width: CGFloat(110 + i * 48), height: CGFloat(110 + i * 48)).rotationEffect(.degrees(-18)) }
                RoundedRectangle(cornerRadius: 25).fill(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 130, height: 130).rotationEffect(.degrees(-18))
                Image(systemName: store.kind.symbol).font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Theme.accent.opacity(0.9))
            }.frame(width: 270, height: 240).padding(.trailing, 30).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, alignment: .leading).background(LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.16), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.055))).clipShape(RoundedRectangle(cornerRadius: 18))
    }
    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.favoritesOnly ? "Your favorites · \(store.kind.title)" : store.categories.first(where: { $0.id == store.category })?.name ?? (store.kind == .live ? "All channels" : "Explore \(store.kind.title.lowercased())")).font(.system(size: 20, weight: .semibold)).tracking(-0.5)
                Text("\(displayed.count)").font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Menu { Button("Provider order") { sortByName = false }; Button("Name A–Z") { sortByName = true } } label: { Label(sortByName ? "Name A–Z" : "Provider order", systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize().font(.caption).foregroundStyle(Theme.muted)
            }
            if store.loading { ProgressView("Loading your library…").frame(maxWidth: .infinity, minHeight: 170) }
            else if let error = store.error {
                VStack(spacing: 14) { Image(systemName: "wifi.exclamationmark").font(.title); Text(error).font(.callout).multilineTextAlignment(.center); Button("Try again") { store.reload(force: true) }.buttonStyle(.bordered) }.padding(30).frame(maxWidth: .infinity)
            } else if displayed.isEmpty {
                ContentUnavailableView(store.favoritesOnly ? "Your favorites belong here" : "Nothing here yet", systemImage: store.favoritesOnly ? "heart" : "magnifyingglass", description: Text(store.favoritesOnly ? "Tap the heart on a title to keep it close." : "Try another category or search, or refresh your library."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: store.kind == .live ? 190 : 155), spacing: 16)], spacing: 20) {
                    ForEach(displayed) { item in
                        MediaCard(item: item, seriesCatalog: store.seriesCatalog, seriesRevision: store.seriesRevision, favorite: store.favorites.contains(item.id), demo: store.demo, open: { if item.kind == .live && !store.demo { play(item) } else { selected = Selection(item: item) } }, toggleFavorite: { store.toggleFavorite(item) }, watchlisted: store.isWatchlisted(item), toggleWatchlist: { store.toggleWatchlist(item) })
                    }
                }
            }
        }
    }
    private func play(_ item: MediaItem, title: MediaItem? = nil, episodes: [MediaItem] = [], episodeChanged: ((MediaItem) -> Void)? = nil) {
        guard store.playbackAllowed() else { return }
        guard !store.demo else { store.showConnection = true; return }
        do {
            let resolve = try store.streamResolver()
            let account = store.viewingAccountKey
            PlayerWindowController.shared.show(item: item, url: try resolve(item), client: store.client,
                episodes: episodes, episodeURL: resolve, episodeChanged: episodeChanged,
                resumeAt: store.viewing.position(for: item), progress: { played, snapshot in
                    store.recordProgress(title: title ?? item, item: played, snapshot: snapshot,
                        next: EpisodeSequence.next(after: played, in: episodes), account: account)
                })
        }
        catch { playError = error.localizedDescription }
    }
}
