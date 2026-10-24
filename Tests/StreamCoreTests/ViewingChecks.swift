import Foundation
import StreamCore

extension StreamCoreChecks {
    func testViewingLibrary() throws {
        let film = MediaItem(streamID: "1", kind: .movie, name: "Film")
        let series = MediaItem(streamID: "1", kind: .series, name: "Series")
        let episode = MediaItem(streamID: "101", kind: .series, name: "Episode 1", season: 1, episode: 1)
        let next = MediaItem(streamID: "102", kind: .series, name: "Episode 2", season: 1, episode: 2)
        let live = MediaItem(streamID: "1", kind: .live, name: "Live")
        var library = ViewingLibrary()
        library.toggleWatchlist(film); library.toggleWatchlist(series); library.toggleWatchlist(live)
        precondition(library.watchlist.map(\.id) == [series.id, film.id])
        library.record(title: film, item: film, snapshot: .init(seconds: 120, duration: 3600, finished: false))
        library.record(title: series, item: episode, snapshot: .init(seconds: 900, duration: 1800, finished: false))
        precondition(library.position(for: episode) == 900 && library.position(for: film) == 120)
        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(ViewingLibrary.self, from: data)
        precondition(restored == library)
        library.record(title: series, item: episode, snapshot: .init(seconds: 0, duration: 0, finished: false))
        library.record(title: series, item: episode, snapshot: .init(seconds: .nan, duration: 1800, finished: false))
        precondition(library.position(for: episode) == 900, "Opening/invalid positions must not overwrite resume")
        library.record(title: series, item: episode, snapshot: .init(seconds: 1700, duration: 1800, finished: false))
        precondition(library.position(for: episode) == 1700, "Stopping near the credits still keeps the position")
        library.record(title: series, item: episode, snapshot: .init(seconds: 1800, duration: 1800, finished: true), next: next)
        precondition(library.progress.first?.item == next && library.progress.first?.seconds == 0)
        precondition(library.progress.first?.timeLabel == "Up next")
        library.record(title: series, item: next, snapshot: .init(seconds: 100, duration: 1800, finished: false))
        precondition(library.progress.filter { $0.title.id == series.id }.count == 1)
        library.record(title: series, item: next, snapshot: .init(seconds: 1800, duration: 1800, finished: true))
        precondition(library.progress.count == 1 && library.progress[0].title == film)
        library.removeProgress(film.id)
        precondition(library.progress.isEmpty)
        library.toggleWatchlist(series)
        precondition(library.watchlist == [film], "History removal does not remove Watchlist entries")
        precondition(ViewingProgress.clock(3661) == "1:01:01")
    }
}
