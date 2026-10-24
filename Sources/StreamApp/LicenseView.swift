import SwiftUI

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
            if license.enabled {
                if license.canStartTrial {
                    action("Start my 3-day free trial", symbol: "arrow.right") { Task { await license.startTrial() } }
                    Text("No card. No automatic charge. The trial starts when you press this button.").font(.caption).foregroundStyle(Theme.muted)
                }
                if license.canSubscribe { action("Subscribe · €4/month", symbol: "arrow.up.right") { Task { await license.openBilling(manage: false) } } }
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
