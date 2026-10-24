import Foundation

public struct SeriesAvailability: Equatable, Sendable {
    public let seasonCount: Int?
    public let hasSpecials: Bool
    public var badge: String {
        guard let count = seasonCount else { return "Seasons unknown" }
        if count == 0 && hasSpecials { return "Specials only" }
        return "\(count) \(count == 1 ? "season" : "seasons")"
    }
    public var explanation: String {
        guard seasonCount != nil else { return "Your provider did not supply reliable season information for this version." }
        return "Seasons with listed episodes for this version." + (hasSpecials ? " Specials are also available." : "")
    }
}

public struct SeriesDetails: Sendable {
    public let episodes: [MediaItem]
    public init(episodes: [MediaItem]) { self.episodes = episodes }
    /// Only promote episode metadata to a series badge when every listed episode agrees.
    public var traits: MediaTraits {
        let resolutions = Set(episodes.compactMap { $0.traits.resolution })
        let allKnown = !episodes.isEmpty && episodes.allSatisfy { $0.traits.resolution != nil }
        return MediaTraits(resolution: allKnown && resolutions.count == 1 ? resolutions.first : nil,
                           multipleSubtitles: !episodes.isEmpty && episodes.allSatisfy { $0.traits.multipleSubtitles })
    }
    public var availability: SeriesAvailability {
        let known = episodes.compactMap(\.season)
        let reliable = known.count == episodes.count && known.allSatisfy { $0 >= 0 }
        return SeriesAvailability(seasonCount: reliable ? Set(known.filter { $0 > 0 }).count : nil,
                                  hasSpecials: known.contains(0))
    }
    public static func parse(_ json: JSONValue, series: MediaItem) throws -> Self {
        // Season metadata can list unaired/empty seasons. Count the actual episode groups instead.
        let groups: [(season: Int?, rows: [JSONValue])]
        if let object = json["episodes"].object {
            groups = object.sorted { $0.key < $1.key }.compactMap { key, value in
                value.array.map { (Int(key), $0) }
            }
            guard groups.count == object.count else { throw ProviderError.invalidResponse }
        } else if let array = json["episodes"].array {
            if array.allSatisfy({ $0.object != nil }) { groups = [(nil, array)] }
            else {
                groups = array.compactMap { $0.array.map { (nil, $0) } }
                guard groups.count == array.count else { throw ProviderError.invalidResponse }
            }
        } else { throw ProviderError.invalidResponse }
        var seen = Set<String>()
        let episodes = groups.flatMap { group in
            group.rows.compactMap { j -> MediaItem? in
                guard let id = j["id"].string, !id.isEmpty, seen.insert(id).inserted else { return nil }
                let explicitSeason = j["season"].string.flatMap(Int.init) ?? j["season_number"].string.flatMap(Int.init)
                let season = explicitSeason ?? group.season
                return MediaItem(streamID: id, kind: .series, name: j["title"].string ?? "Episode",
                    artwork: series.artwork, fileExtension: j["container_extension"].string ?? "mp4",
                    plot: j["info"]["plot"].string, season: season,
                    episode: j["episode_num"].string.flatMap(Int.init),
                    traits: MediaTraits.from(name: j["title"].string ?? "", metadata: j["info"]))
            }
        }.sorted { ($0.season ?? Int.max, $0.episode ?? 0, $0.streamID) < ($1.season ?? Int.max, $1.episode ?? 0, $1.streamID) }
        if episodes.isEmpty && groups.contains(where: { !$0.rows.isEmpty }) { throw ProviderError.invalidResponse }
        return Self(episodes: episodes)
    }
}
