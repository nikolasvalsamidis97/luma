import SwiftUI

/// Always visible in the library and welcome screen; the player stays distraction-free.
struct LicenseBanner: View {
    @ObservedObject var license: LicenseStore
    var body: some View {
        HStack(spacing: 12) {
            Label(license.badge, systemImage: license.hasFullAccess ? "checkmark.seal.fill" : "clock")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(Theme.accent.opacity(0.1), in: Capsule())
            Text(!license.enabled ? "3-day trial and subscriptions coming soon" : license.trialRemaining)
                .font(.caption).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Button { license.showAccount = true } label: {
                Text(license.hasFullAccess ? "Manage access" : "Upgrade to full version")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.horizontal, 24).padding(.vertical, 10).background(Theme.sidebar)
    }
}

struct LicenseView: View {
    @ObservedObject var license: LicenseStore
    var canClose = false
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Brand(); Spacer(); if canClose { Button("Done") { dismiss() }.buttonStyle(.plain) } }
            Image(systemName: license.grant?.status == "developer" ? "key.fill" : "play.rectangle")
                .font(.system(size: 35, weight: .light)).foregroundStyle(Theme.accent).padding(.top, 12)
            Text(license.title).font(.system(size: 30, weight: .semibold)).tracking(-0.7)
            Text(license.detail).font(.system(size: 14)).foregroundStyle(Theme.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            if !license.hasFullAccess {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("3-day free trial", systemImage: "clock").font(.headline)
                        Spacer()
                        Text(license.enabled ? license.trialRemaining : "Coming soon").font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text("Then €4/month for the full version").font(.subheadline)
                    Text("No card to start. Nothing is charged when your trial ends. If you subscribe, €4 is billed each month until you cancel.")
                        .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            if license.enabled {
                if license.canStartTrial {
                    action("Start my 3-day free trial", symbol: "arrow.right") { Task { await license.startTrial() } }
                    Text("No card. No automatic charge. The trial starts when you press this button.").font(.caption).foregroundStyle(Theme.muted)
                }
                if license.canSubscribe { action("Subscribe · €4/month", symbol: "arrow.up.right") { Task { await license.openBilling(manage: false) } } }
                else if license.grant?.status == "trial" {
                    Text("Enjoy your trial first. Subscription checkout opens when your trial ends.").font(.caption).foregroundStyle(Theme.muted)
                } else if license.grant?.status == "expired", license.grant?.billingAvailable != true {
                    Text("Subscription checkout is currently unavailable. Refresh access to check again, or use a product key below.").font(.caption).foregroundStyle(Theme.muted)
                }
                if license.grant?.hasSubscription == true {
                    Button("Manage or cancel subscription ↗") { Task { await license.openBilling(manage: true) } }.buttonStyle(.bordered)
                }
                Divider().overlay(.white.opacity(0.06))
                Text("HAVE A PRODUCT KEY?").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(Theme.muted)
                HStack {
                    SecureField("LUMA-…", text: $key).textFieldStyle(.plain).padding(13).background(Theme.panel,in:RoundedRectangle(cornerRadius:8)).onSubmit { activate() }
                    Button("Activate") { activate() }.buttonStyle(.bordered).disabled(key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Text("Developer keys unlock the full app without a subscription. You can also restore a subscription with its saved product key.").font(.caption).foregroundStyle(Theme.muted).lineSpacing(3)
                HStack {
                    Button("Refresh access") { Task { await license.refresh() } }.buttonStyle(.plain)
                    Spacer()
                    if license.canCopyKey { Button("Copy my product key") { license.copyProductKey() }.buttonStyle(.plain) }
                }.font(.caption).foregroundStyle(Theme.accent)
            }
            if let message = license.message { Text(message).font(.caption).foregroundStyle(Theme.accent).fixedSize(horizontal:false,vertical:true) }
            if license.busy { ProgressView().controlSize(.small) }
            if license.enabled {
                Text("Activation uses a hashed Mac identifier and a private activation token. Provider logins and viewing history are not sent to the licensing service.").font(.system(size:11)).foregroundStyle(Theme.muted).lineSpacing(3)
                Text("A TV subscription is not included. Internet access is required to verify your Luma license.").font(.system(size:11)).foregroundStyle(Theme.muted)
                HStack(spacing: 16) {
                    Link("Subscription details", destination: URL(string: "https://nikolasvalsamidis97.github.io/luma/billing.html")!)
                    Link("Privacy", destination: URL(string: "https://nikolasvalsamidis97.github.io/luma/privacy.html")!)
                    Link("Support", destination: URL(string: "mailto:nikolasvalsamidis97@gmail.com")!)
                }.font(.caption).foregroundStyle(Theme.accent)
            }
        }.padding(38).frame(width:500).background(Theme.background).foregroundStyle(.white)
            .disabled(license.busy)
    }
    private func activate() {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await license.activate(key); if license.allowed { key = "" } }
    }
    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action:perform) { HStack { Text(title).fontWeight(.semibold); Spacer(); Image(systemName:symbol) }.padding(15).frame(maxWidth:.infinity) }
            .buttonStyle(.plain).background(Theme.accent,in:RoundedRectangle(cornerRadius:9)).foregroundStyle(.black)
    }
}
