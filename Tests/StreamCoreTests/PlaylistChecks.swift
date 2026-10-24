import Foundation
import StreamCore

extension StreamCoreChecks {
    func testSavedPlaylists() throws {
        let first = try Credentials(server: "https://one.test", username: "same-user", password: "one")
        let second = try Credentials(server: "https://two.test", username: "same-user", password: "two")
        var saved = SavedPlaylists()
        let one = saved.remember(.init(credentials: first, playlistURL: nil, name: "Home"))
        let two = saved.remember(.init(credentials: second, playlistURL: nil, name: "Sports"))
        precondition(one != two && saved.connections.count == 2 && saved.active?.credentials == second)
        precondition(saved.connections[0].accountKey != saved.connections[1].accountKey)
        let rotated = try Credentials(server: "https://one.test", username: "same-user", password: "changed")
        let updated = saved.remember(.init(credentials: rotated, playlistURL: nil))
        precondition(updated == one && saved.connections.count == 2 && saved.active?.name == "Home" && saved.active?.credentials?.password == "changed")
        saved.rename(one, to: "  Living room  "); precondition(saved.active?.name == "Living room")
        saved.activeID = two
        let roundtrip = try SavedPlaylists.decode(JSONEncoder().encode(saved))
        precondition(roundtrip == saved && roundtrip.active?.id == two)
        let old = try SavedPlaylists.decode(JSONEncoder().encode(first))
        precondition(old.connections.count == 1 && old.active?.credentials == first)
        let legacyEnvelope = try JSONSerialization.data(withJSONObject: ["credentials": JSONSerialization.jsonObject(with: JSONEncoder().encode(first))])
        let migrated = try SavedPlaylists.decode(legacyEnvelope)
        precondition(migrated.connections.count == 1 && migrated.active?.displayName == "one.test")
        let oldM3U = try SavedPlaylists.decode(Data(#"{"playlistURL":"https://m3u.test/list?secret=one"}"#.utf8))
        precondition(oldM3U.active?.sourceType == "M3U")
        saved.remember(oldM3U.active!); precondition(saved.connections.count == 3)
        saved.activeID = nil
        let disconnected = try SavedPlaylists.decode(JSONEncoder().encode(saved))
        precondition(disconnected.active == nil && disconnected.connections.count == 3)
        saved.activeID = two; saved.remove(one)
        precondition(saved.active?.id == two && saved.connections.count == 2)
        saved.remove(two); precondition(saved.active == nil && saved.connections.count == 1)
        do { _ = try SavedPlaylists.decode(Data("{}".utf8)); preconditionFailure("Invalid vault accepted") } catch {}
    }
}
