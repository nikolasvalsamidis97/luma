import SwiftUI

struct ConnectionForm: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let isSheet: Bool
    @State private var playlistMode = false
    @State private var playlistLink = ""
    @State private var playlistName = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focused: Field?
    enum Field { case server, username, password, playlist, name }
    private var incomplete: Bool { playlistMode ? playlistLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : server.isEmpty || username.isEmpty || password.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Image(systemName: "link").font(.title2).foregroundStyle(Theme.accent).padding(14).background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14)); Spacer(); if isSheet { Button("Cancel") { store.cancelConnection(); dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary) } }
            VStack(alignment: .leading, spacing: 9) { Text("Your TV starts here.").font(.system(size: 28, weight: .semibold)).tracking(-0.7); Text(playlistMode ? "Paste the M3U playlist link from your TV provider." : "Connect with the Xtream Codes details\nfrom your TV provider.").font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(4) }
            if !isSheet && !store.savedPlaylists.connections.isEmpty {
                Menu("Saved playlists") {
                    ForEach(store.savedPlaylists.connections) { playlist in
                        Button(playlist.displayName) { store.switchPlaylist(playlist.id) }
                    }
                    Divider()
                    Button("Manage playlists…") { store.loginError = nil; store.showPlaylists = true }
                }.disabled(store.connecting)
            }
            Picker("Source", selection: $playlistMode) { Text("Xtream Codes").tag(false); Text("M3U link").tag(true) }.pickerStyle(.segmented).disabled(store.connecting)
            VStack(alignment: .leading, spacing: 17) {
                field("PLAYLIST NAME (OPTIONAL)") { TextField("e.g. Home TV", text: $playlistName).focused($focused, equals: .name) }
                if playlistMode {
                    field("PLAYLIST LINK") { SecureField("https://provider.com/playlist.m3u", text: $playlistLink).focused($focused, equals: .playlist) }
                    Text("Channels, movies and numbered episodes are organized using the information in your playlist.").font(.caption).foregroundStyle(Theme.muted)
                } else {
                field("SERVER ADDRESS") { TextField("https://provider.com:8080", text: $server).textContentType(.URL).focused($focused, equals: .server) }
                field("USERNAME") { TextField("Your username", text: $username).textContentType(.username).focused($focused, equals: .username) }
                field("PASSWORD") { SecureField("Your password", text: $password).textContentType(.password).focused($focused, equals: .password) }
                }
            }.textFieldStyle(.plain)
            Toggle("Remember login in macOS Keychain", isOn: $remember).font(.caption).toggleStyle(.checkbox).foregroundStyle(Theme.muted)
            if let error = store.loginError { Text(error).font(.caption).foregroundStyle(Theme.accent).fixedSize(horizontal: false, vertical: true) }
            Button(action: connect) {
                HStack { Spacer(); if store.connecting { ProgressView().controlSize(.small) }; Text(store.connecting ? "Connecting…" : "Connect your library").fontWeight(.semibold); if !store.connecting { Image(systemName: "arrow.right") }; Spacer() }.padding(.vertical, 14)
            }.buttonStyle(.plain).background(Theme.accent, in: RoundedRectangle(cornerRadius: 10)).disabled(store.connecting || incomplete).opacity(incomplete ? 0.6 : 1)
            if !isSheet {
                Button { store.preview() } label: { HStack { Spacer(); Text("Take a look around"); Image(systemName: "arrow.up.right"); Spacer() }.font(.system(size: 13)).foregroundStyle(Theme.muted) }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 7) { Image(systemName: "lock.shield"); Text("Your login stays on this Mac. Luma connects directly to your provider.").lineSpacing(3) }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 5)
        }.onSubmit { if focused == .name { focused = playlistMode ? .playlist : .server } else if focused == .server { focused = .username } else if focused == .username { focused = .password } else { connect() } }
    }
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(label).font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(Theme.muted); content().padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.07))) }
    }
    private func connect() { guard !store.connecting else { return }; if playlistMode { store.connectPlaylist(playlistLink, remember: remember, name: playlistName) } else { store.connect(server: server, username: username, password: password, remember: remember, name: playlistName) } }
}
