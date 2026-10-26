import AppKit
import SwiftUI
import Foundation
import StreamCore

@main struct LicensingCheck {
    @MainActor static func main() {
        setbuf(stdout,nil)
        let app=NSApplication.shared; app.setActivationPolicy(.regular)
        let server=URL(string:CommandLine.arguments[1])!
        let key=try! String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8)
        let vault=LicenseVault(service:"com.luma.license-checks." + UUID().uuidString)
        let license=LicenseStore(server:server,enabled:true,vault:vault)
        let free=LicenseStore(enabled:false,vault:vault)
        precondition(free.allowed && free.badge == "Free early access" && free.trialRemaining.isEmpty && !free.canSubscribe)
        precondition(license.badge == "3-day free trial" && license.canStartTrial)
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:850),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title="Luma · Activation checks"; w.isReleasedWhenClosed=false
        w.contentView=NSHostingView(rootView:LicenseView(license:license).frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.background).preferredColorScheme(.dark))
        w.center(); w.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
        license.start()
        Task { @MainActor in
            @MainActor func capture(_ store: LicenseStore, name: String) async {
                guard CommandLine.arguments.contains("--screenshots") else { return }
                w.setContentSize(NSSize(width: 1000, height: 850))
                w.contentView=NSHostingView(rootView: VStack(spacing: 0) {
                    ScrollView { LicenseView(license:store).frame(maxWidth:.infinity) }.frame(maxWidth:.infinity,maxHeight:.infinity)
                    LicenseBanner(license:store)
                }.background(Theme.background).preferredColorScheme(.dark))
                try? await Task.sleep(for: .milliseconds(300))
                let view=w.contentView!; view.layoutSubtreeIfNeeded()
                let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/luma-access-\(name).png"))
            }
            if CommandLine.arguments.contains("--manual") { print("READY: isolated activation UI; press Start my 3-day free trial"); return }
            await capture(free,name:"early-access")
            await license.startTrial(); precondition(license.allowed && license.grant?.status=="trial"); precondition(license.canCopyKey)
            precondition(license.badge == "3-day free trial" && license.trialRemaining == "3 days left" && !license.canStartTrial && !license.canSubscribe)
            await capture(license,name:"trial")
            print("PASS: HTTP trial activation and Keychain recovery key")
            let restored=LicenseStore(server:server,enabled:true,vault:vault)
            await restored.refresh(); precondition(restored.allowed && restored.grant?.trialEndsAt==license.grant?.trialEndsAt)
            print("PASS: restart restores existing trial without resetting expiry")
            _=try! await URLSession.shared.data(from:server.appendingPathComponent("test/last-hour"))
            await license.refresh(); precondition(license.trialRemaining == "30 min left")
            print("PASS: trial countdown shows remaining minutes on the last day")
            _=try! await URLSession.shared.data(from:server.appendingPathComponent("test/expire"))
            await license.refresh(); precondition(!license.allowed)
            precondition(license.badge == "Trial ended" && license.trialRemaining.isEmpty && !license.hasFullAccess)
            await capture(license,name:"expired")
            await license.activate("wrong-key"); precondition(!license.allowed && license.message != nil)
            await license.activate(key); precondition(license.allowed && license.grant?.status=="developer")
            precondition(license.hasFullAccess && license.badge == "Developer · Full version" && license.trialRemaining.isEmpty)
            await capture(license,name:"developer")
            print("PASS: expired trial denied, invalid key denied, developer key unlocks")
            _=try! await URLSession.shared.data(from:server.appendingPathComponent("test/revoke"))
            await license.refresh(); precondition(!license.allowed)
            print("PASS: revoked developer access closes the access gate")
            print("PASS: production LicenseStore + LicenseView integration")
            app.terminate(nil)
        }
        app.run()
    }
}
