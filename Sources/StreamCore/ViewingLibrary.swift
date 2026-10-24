import Foundation

public struct PlaybackSnapshot: Equatable, Sendable {
    public let seconds: Double
    public let duration: Double
    public let finished: Bool
    public init(seconds: Double, duration: Double, finished: Bool) {
        self.seconds = seconds; self.duration = duration; self.finished = finished
    }
}

public struct ViewingProgress: Codable, Identifiable, Equatable, Sendable {
    public var id: String { title.id }
    public let title: MediaItem
    public let item: MediaItem
    public let seconds: Double
    public let duration: Double
    public let updated: Date
    public var fraction: Double { duration > 0 ? min(1, max(0, seconds / duration)) : 0 }
    public var timeLabel: String {
        guard seconds > 0 else { return "Up next" }
        return "Resume at \(Self.clock(seconds))"
    }
    public static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max) else { return "00:00" }
        let value = Int(seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) :
            String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Metadata and positions only; playback URLs are rebuilt from the current account.
public struct ViewingLibrary: Codable, Equatable, Sendable {
    public private(set) var progress: [ViewingProgress] = []
    public private(set) var watchlist: [MediaItem] = []
    public init() {}
    public func position(for item: MediaItem) -> Double {
        progress.first { $0.item.id == item.id }?.seconds ?? 0
    }
    public mutating func toggleWatchlist(_ item: MediaItem) {
        guard item.kind != .live else { return }
        if watchlist.contains(where: { $0.id == item.id }) { watchlist.removeAll { $0.id == item.id } }
        else { watchlist.insert(item, at: 0); watchlist = Array(watchlist.prefix(500)) }
    }
    public mutating func removeProgress(_ id: String) { progress.removeAll { $0.id == id } }
    public mutating func record(title: MediaItem, item: MediaItem, snapshot: PlaybackSnapshot, next: MediaItem? = nil, now: Date = Date()) {
        guard title.kind != .live, title.kind == item.kind,
              snapshot.seconds.isFinite, snapshot.duration.isFinite,
              snapshot.seconds >= 0, snapshot.duration >= 0 else { return }
        if snapshot.finished {
            removeProgress(title.id)
            if title.kind == .series, let next, next.kind == .series {
                progress.insert(ViewingProgress(title: title, item: next, seconds: 0, duration: 0, updated: now), at: 0)
            }
        } else {
            // Do not replace a valid bookmark with the opening/failed stream's zero time.
            guard snapshot.seconds >= 1 else { return }
            removeProgress(title.id)
            progress.insert(ViewingProgress(title: title, item: item,
                seconds: snapshot.duration > 0 ? min(snapshot.seconds, snapshot.duration) : snapshot.seconds,
                duration: snapshot.duration, updated: now), at: 0)
        }
        progress = Array(progress.prefix(200))
    }
}
