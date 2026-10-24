import SwiftUI
import StreamCore

/// Session-only observations; clear when the account or library is refreshed.
@MainActor final class MediaFactsStore: ObservableObject {
    static let shared = MediaFactsStore()
    @Published private var values: [String: MediaTraits] = [:]
    func traits(for item: MediaItem) -> MediaTraits { values[item.id] ?? MediaTraits() }
    func record(_ traits: MediaTraits, for item: MediaItem) {
        let updated = traits.supplemented(by: values[item.id] ?? MediaTraits())
        guard updated != values[item.id] else { return }
        if values.count >= 2048 { values.removeAll() }
        values[item.id] = updated
    }
    func clear() { values.removeAll() }
}
