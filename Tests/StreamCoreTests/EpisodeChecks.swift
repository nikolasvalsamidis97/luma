import StreamCore

extension StreamCoreChecks {
    func testEpisodeSequence() {
        func episode(_ id: String, _ season: Int?, _ number: Int?) -> MediaItem {
            MediaItem(streamID: id, kind: .series, name: id, season: season, episode: number)
        }
        let special = episode("special", 0, 1), secondSpecial = episode("special2", 0, 2)
        let first = episode("first", 1, 1), second = episode("second", 1, 2)
        let duplicateNumber = episode("duplicate", 1, 1), nextSeason = episode("nextSeason", 2, 1)
        let unknown = episode("unknown", nil, nil)
        let unsorted = [unknown, nextSeason, second, first, special, duplicateNumber, secondSpecial]
        precondition(EpisodeSequence.next(after: first, in: unsorted) == second)
        precondition(EpisodeSequence.next(after: second, in: unsorted) == nextSeason)
        precondition(EpisodeSequence.next(after: nextSeason, in: unsorted) == nil)
        precondition(EpisodeSequence.next(after: unknown, in: unsorted) == nil)
        precondition(EpisodeSequence.next(after: special, in: unsorted) == secondSpecial)
        precondition(EpisodeSequence.next(after: secondSpecial, in: unsorted) == nil)
        precondition(EpisodeSequence.next(after: episode("otherVersion", 1, 1), in: unsorted) == nil)
        precondition(!EpisodeSequence.shouldOfferNext(elapsed: 1709, duration: 1800, finished: false))
        precondition(EpisodeSequence.shouldOfferNext(elapsed: 1710, duration: 1800, finished: false))
        precondition(!EpisodeSequence.shouldOfferNext(elapsed: 20, duration: 60, finished: false))
        precondition(EpisodeSequence.shouldOfferNext(elapsed: 54, duration: 60, finished: false))
        precondition(!EpisodeSequence.shouldOfferNext(elapsed: 0, duration: 0, finished: false))
        precondition(EpisodeSequence.shouldOfferNext(elapsed: 0, duration: 0, finished: true))
        precondition(!EpisodeSequence.shouldOfferNext(elapsed: .nan, duration: 1800, finished: false))
    }
}
