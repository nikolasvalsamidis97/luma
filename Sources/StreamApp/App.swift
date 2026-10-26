import SwiftUI
import AppKit

@main struct LumaApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var license = LicenseStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Luma", id: "main") {
            RootView().environmentObject(store).environmentObject(license).preferredColorScheme(.dark).tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 690)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1260, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { Button("Luma Access…") { license.showAccount = true } }
            CommandGroup(after: .toolbar) {
                Button("Refresh library") { store.reload(force: true) }.keyboardShortcut("r").disabled(!store.connected)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { PlayerWindowController.shared.close() }
}


struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var license: LicenseStore
    var body: some View {
        Group {
            if !license.allowed { ScrollView { LicenseView(license: license).frame(maxWidth: .infinity) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if store.connected { LibraryView() }
            else { WelcomeView() }
        }.background(Theme.background).foregroundStyle(.white)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if license.allowed { LicenseBanner(license: license) }
        }
        .task {
            store.playbackAllowed = { license.allowed }
            store.beforeSourceChange = { PlayerWindowController.shared.close() }
            license.start()
        }
        .onChange(of: license.allowed) { _, allowed in
            if !allowed { PlayerWindowController.shared.close(); store.showConnection = false }
        }
        .sheet(isPresented: $store.showPlaylists) { PlaylistManager().environmentObject(store) }
        .sheet(isPresented: $license.showAccount) {
            ScrollView { LicenseView(license: license, canClose: true) }.frame(width: 500).frame(maxHeight: 720).background(Theme.background)
        }
        .sheet(isPresented: $store.showConnection, onDismiss: { store.cancelConnection() }) {
            ScrollView { ConnectionForm(isSheet: true).environmentObject(store).frame(width: 480).padding(36) }.frame(maxHeight: 700).background(Theme.background)
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Brand().padding(.bottom, 72)
                Text("YOUR WORLD.\nNOW SHOWING.").font(.system(size: 11, weight: .bold)).tracking(3).foregroundStyle(Theme.accent).padding(.bottom, 22)
                Text("A better seat\nfor every story.").font(.system(size: 53, weight: .semibold)).tracking(-2).lineSpacing(-1)
                Text("Live television. Movie nights. One more episode.\nAll your entertainment, beautifully at home on Mac.").font(.system(size: 15)).foregroundStyle(Theme.muted).lineSpacing(6).padding(.top, 24)
                HStack(spacing: 12) {
                    feature("tv", "Live TV"); feature("film", "Movies"); feature("rectangle.stack", "Series")
                }.padding(.top, 36)
                Spacer(minLength: 40)
                HStack(spacing: 8) { Image(systemName: "macwindow"); Text("Made for your Mac. Made for your downtime.") }.font(.caption).foregroundStyle(Theme.muted)
            }.padding(54).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background {
                    ZStack { Theme.sidebar; Circle().fill(Theme.accent.opacity(0.10)).frame(width: 450).blur(radius: 100).offset(x: -150, y: 180); Circle().fill(Color.blue.opacity(0.12)).frame(width: 350).blur(radius: 100).offset(x: 170, y: -150) }.clipped()
                }
            ScrollView { ConnectionForm(isSheet: false).frame(width: 360).padding(40) }.frame(width: 440)
        }
    }
    private func feature(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 11).background(.white.opacity(0.05), in: Capsule())
    }
}
