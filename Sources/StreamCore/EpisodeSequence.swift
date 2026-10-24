import Foundation

public enum EpisodeSequence {
    /// Use only episodes from the selected provider entry. Keep specials separate.
    public static func next(after current: MediaItem, in episodes: [MediaItem]) -> MediaItem? {
        guard current.kind == .series, let season = current.season, let number = current.episode,
              episodes.contains(where: { $0.id == current.id }) else { return nil }
        return episodes.filter {
            guard $0.kind == .series, let s = $0.season, let e = $0.episode else { return false }
            return $0.id != current.id && (season > 0 ? s > 0 : s == season) && (s, e) > (season, number)
        }.sorted {
            ($0.season!, $0.episode!, $0.streamID) < ($1.season!, $1.episode!, $1.streamID)
        }.first
    }

    public static func shouldOfferNext(elapsed: Double, duration: Double, finished: Bool) -> Bool {
        if finished { return true }
        guard elapsed.isFinite, duration.isFinite, duration > 0, elapsed > 0 else { return false }
        // Avoid covering most of a short episode; normal episodes use the final 90 seconds.
        return duration - elapsed <= min(90, duration * 0.1)
    }
}
