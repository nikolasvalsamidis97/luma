import SwiftUI
import StreamCore

struct PlaylistManager: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Your playlists").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Keep several providers and switch from the playlist menu. Each has its own saved progress.").font(.callout).foregroundStyle(Theme.muted)
            if store.savedPlaylists.connections.isEmpty {
                Text("No saved playlists yet. Use Add playlist to connect one.").foregroundStyle(Theme.muted).padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.savedPlaylists.connections) { playlist in
                            PlaylistRow(playlist: playlist, active: store.activePlaylistID == playlist.id,
                                rename: { store.renamePlaylist(playlist.id, to: $0) }, remove: { store.removePlaylist(playlist.id) })
                        }
                    }
                }.frame(maxHeight: 360)
            }
            if let error = store.loginError { Text(error).font(.caption).foregroundStyle(Theme.accent) }
        }.padding(28).frame(width: 520).background(Theme.background).foregroundStyle(.white)
    }
}
private struct PlaylistRow: View {
    let playlist: SavedConnection
    let active: Bool
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var name: String
    init(playlist: SavedConnection, active: Bool, rename: @escaping (String) -> Void, remove: @escaping () -> Void) {
        self.playlist = playlist; self.active = active; self.rename = rename; self.remove = remove
        _name = State(initialValue: playlist.displayName)
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Playlist name", text: $name).textFieldStyle(.roundedBorder).onSubmit { rename(name) }
                Text(playlist.sourceType + (active ? " · Current playlist" : "")).font(.caption).foregroundStyle(Theme.muted)
            }
            Button("Save name") { rename(name) }.disabled(name == playlist.displayName)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Remove saved playlist").accessibilityLabel("Remove \(playlist.displayName)")
        }.padding(14).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}
