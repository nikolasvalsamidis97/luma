import SwiftUI
import StreamCore

struct MediaCard: View {
    let item: MediaItem
    let seriesCatalog: SeriesCatalog?
    let seriesRevision: UUID
    @ObservedObject private var facts = MediaFactsStore.shared
    @State private var seriesTraits = MediaTraits()
    private var traits: MediaTraits { facts.traits(for: item).supplemented(by: item.traits).supplemented(by: seriesTraits) }
    @State private var availability: SeriesAvailability?
    @State private var availabilityError: String?
    @State private var seasonRetry = 0
    private struct SeasonRequest: Equatable { let revision: UUID; let retry: Int }
    let favorite: Bool
    let demo: Bool
    let open: () -> Void
    let toggleFavorite: () -> Void
    var watchlisted = false
    var toggleWatchlist: (() -> Void)? = nil
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Button(action: open) {
                    Artwork(item: item).frame(height: item.kind == .live ? 122 : 212).clipped()
                        .overlay { if hovering { Color.black.opacity(0.2); Image(systemName: "play.circle.fill").font(.system(size: 38)).foregroundStyle(.white) } }
                }.buttonStyle(.plain).accessibilityLabel("Open \(item.name)")
                VStack(spacing: 7) {
                    Button(action: toggleFavorite) { Image(systemName: favorite ? "heart.fill" : "heart").font(.system(size: 12)).foregroundStyle(favorite ? Theme.accent : .white.opacity(0.8)).padding(8).background(.black.opacity(0.3), in: Circle()) }.buttonStyle(.plain).help(favorite ? "Remove favorite" : "Add favorite")
                    if item.kind != .live, let toggleWatchlist {
                        Button(action: toggleWatchlist) { Image(systemName: watchlisted ? "bookmark.fill" : "bookmark").font(.system(size: 12)).foregroundStyle(watchlisted ? Theme.accent : .white.opacity(0.8)).padding(8).background(.black.opacity(0.5), in: Circle()) }
                            .buttonStyle(.plain).help(watchlisted ? "Remove from Watchlist" : "Add to Watchlist")
                            .accessibilityLabel("\(watchlisted ? "Remove from" : "Add to") Watchlist: \(item.name)")
                    }
                }.padding(9)
                VStack(alignment: .leading, spacing: 5) {
                    if let resolution = traits.resolution { mediaBadge(resolution, symbol: "sparkles.tv") }
                    if traits.multipleSubtitles { mediaBadge("MULTISUB", symbol: "captions.bubble.fill") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
                    .help("Resolution and subtitle information from provider labels, metadata or observed playback.")
                    .allowsHitTesting(false)
                if item.kind == .live { Text("LIVE").font(.system(size: 8, weight: .bold)).tracking(1).padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.3), in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10).allowsHitTesting(false) }
                if item.kind == .series && !demo {
                    HStack(spacing: 5) {
                        Label(availability?.badge ?? (availabilityError == nil ? "Seasons…" : "Retry seasons"), systemImage: "rectangle.stack.fill")
                        if availabilityError != nil {
                            Button { seasonRetry += 1 } label: { Image(systemName: "arrow.clockwise").padding(2) }
                                .buttonStyle(.plain).accessibilityLabel("Retry seasons for \(item.name)")
                        }
                    }
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.78), in: Capsule())
                        .help(availabilityError ?? availability?.explanation ?? "Checking this version’s available seasons…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
                }
            }.frame(height: item.kind == .live ? 122 : 212).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(hovering ? 0.18 : 0.06)))
            Button(action: open) { Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1) }.buttonStyle(.plain)
            Text(demo ? "Sample \(item.kind == .live ? "channel" : "title")" : item.kind == .live ? "Watch live" : (item.rating.flatMap { $0.isEmpty || $0 == "0" ? nil : "★ \($0)" } ?? item.kind.title)).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.onHover { hovering = $0 }
        .task(id: SeasonRequest(revision: seriesRevision, retry: seasonRetry)) {
            availability = nil; availabilityError = nil; seriesTraits = MediaTraits()
            guard item.kind == .series, !demo, let seriesCatalog else { return }
            do {
                // Avoid starting provider requests for cards briefly crossed while scrolling.
                try await Task.sleep(for: .milliseconds(180))
                let details = try await seriesCatalog.details(for: item)
                try Task.checkCancellation()
                availability = details.availability; seriesTraits = details.traits
            } catch is CancellationError { }
            catch { if !Task.isCancelled { availabilityError = error.localizedDescription } }
        }
    }
    private func mediaBadge(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 5)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct Artwork: View {
    let item: MediaItem
    var compact = false
    private var tint: Color {
        let colors: [Color] = [.teal, .indigo, .orange, .blue, .purple, .pink, .green, .cyan]
        return colors[item.name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [tint.opacity(0.28), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().stroke(tint.opacity(0.18), lineWidth: 1).frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9).offset(x: geo.size.width * 0.35, y: -30)
                Circle().fill(tint.opacity(0.10)).frame(width: geo.size.width * 0.8).offset(x: -geo.size.width * 0.3, y: 80)
                if item.kind == .live {
                    VStack(spacing: 7) { Image(systemName: "play.tv").font(.system(size: 24, weight: .light)); Text(String(item.name.prefix(20)).uppercased()).font(.system(size: 9, weight: .heavy)).tracking(1.6).multilineTextAlignment(.center) }.foregroundStyle(.white.opacity(0.8)).padding(16)
                } else if compact {
                    Image(systemName: item.kind.symbol).font(.system(size: 20, weight: .light)).foregroundStyle(tint)
                } else {
                    VStack { Spacer(); Image(systemName: item.kind.symbol).font(.system(size: 35, weight: .ultraLight)).foregroundStyle(tint.opacity(0.8)); Spacer(); Text(item.name.uppercased()).font(.system(size: 20, weight: .heavy, design: .serif)).multilineTextAlignment(.center).tracking(1).padding(.bottom, 24) }.padding(18)
                }
                if let url = item.artwork, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: item.kind == .live ? .fit : .fill).frame(width: geo.size.width, height: geo.size.height).background(Theme.panel) } placeholder: { Color.clear }
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.accessibilityHidden(true)
    }
}
