import AppKit
import CryptoKit
import Foundation
import Darwin
import IOKit
import Security
import StreamCore

@MainActor final class LicenseStore: ObservableObject {
    @Published private(set) var grant: LicenseGrant?
    @Published private(set) var allowed = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var showAccount = false
    @Published private(set) var hasIdentity = false
    @Published private(set) var trialRemaining = ""
    let enabled: Bool
    private let server: URL?
    private var identity: LicenseIdentity?
    private var receivedAt: TimeInterval = 0
    private var lastRefresh: TimeInterval = -60
    private var timer: Timer?
    private let session: URLSession
    private var started = false
    private var productKey: String?
    private let vault: LicenseVault
    init(server: URL? = nil, enabled: Bool? = nil, vault: LicenseVault = LicenseVault()) {
        self.enabled = enabled ?? (Bundle.main.object(forInfoDictionaryKey: "LumaLicensingEnabled") as? Bool ?? false)
        self.server = server ?? (Bundle.main.object(forInfoDictionaryKey: "LumaLicenseServerURL") as? String).flatMap(URL.init(string:))
        self.vault = vault
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config)
        allowed = !self.enabled
    }
    var canStartTrial: Bool { identity?.activated != true }
    var canSubscribe: Bool { grant?.status == "expired" && grant?.billingAvailable == true }
    var hasFullAccess: Bool { enabled && allowed && ["active", "developer"].contains(grant?.status ?? "") }
    var badge: String {
        guard enabled else { return "Free early access" }
        guard let grant else { return hasIdentity ? "Verify access" : "3-day free trial" }
        if grant.status == "expired" { return grant.trialEndsAt > 0 ? "Trial ended" : "Access inactive" }
        guard allowed else { return "Verify access" }
        switch grant.status {
        case "trial": return "3-day free trial"
        case "developer": return "Developer · Full version"
        case "active": return "Full version"
        default: return "Access inactive"
        }
    }
    var title: String {
        guard enabled else { return "Luma full version" }
        guard let grant else { return hasIdentity ? "Refresh your access" : "Make yourself comfortable." }
        switch grant.status {
        case "developer": return "Developer access"
        case "active": return "Luma subscription"
        case "trial": return allowed ? "Your free trial is running" : "Refresh your access"
        default: return grant.trialEndsAt > 0 ? "Your free trial has ended" : "Your access is inactive"
        }
    }
    var detail: String {
        if !enabled { return "You’re using the free early-access version. Trials and upgrades aren’t available yet, so there’s no countdown and no payment required in this release." }
        guard let grant else { return "Try all of Luma for 3 days. No payment card required. Then €4/month if you choose to subscribe." }
        switch grant.status {
        case "developer": return "Full access with your developer product key. No subscription needed."
        case "active": return "€4/month. Manage your subscription or cancel through the billing portal."
        case "trial":
            let date = Date(timeIntervalSince1970: grant.trialEndsAt)
            return "Full access until \(date.formatted(date: .abbreviated, time: .shortened)). Nothing is charged automatically."
        default: return grant.trialEndsAt == 0 ? "Refresh your access or enter another product key. Contact your key issuer if access was revoked." : "Subscribe for €4/month to keep watching, or activate a product key. Your library and watch history stay on this Mac."
        }
    }
    func start() {
        guard enabled, !started else { return }; started = true
        do { identity = try vault.load(); hasIdentity = identity != nil; productKey = identity?.productKey }
        catch { message = "macOS Keychain could not load your Luma activation. Try again." }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateAllowed()
                if self.identity?.activated == true && !self.busy && LicenseClock.seconds-self.lastRefresh >= 60 { await self.refresh() }
            }
        }
        if identity?.activated == true { Task { await refresh() } }
    }
    private func updateAllowed() {
        let next = !enabled || (grant?.permitsPlayback(receivedAt: receivedAt, currentUptime: LicenseClock.seconds) ?? false)
        if allowed != next { allowed = next }
        let remaining: String
        if let grant, grant.status == "trial", next {
            let seconds = max(0, grant.trialEndsAt - grant.serverTime - max(0, LicenseClock.seconds - receivedAt))
            if seconds > 86400 { remaining = "\(Int(ceil(seconds / 86400))) days left" }
            else if seconds > 3600 { remaining = "\(Int(ceil(seconds / 3600))) hours left" }
            else { remaining = "\(max(1, Int(ceil(seconds / 60)))) min left" }
        } else { remaining = "" }
        if trialRemaining != remaining { trialRemaining = remaining }
    }
    private func prepareIdentity() throws -> LicenseIdentity {
        if let identity { return identity }
        if let saved = try vault.load() { identity = saved; hasIdentity = true; return saved }
        let created = try LicenseIdentity.make()
        try vault.save(created); identity = created; hasIdentity = true
        return created
    }
    private func endpoint(_ route: String) throws -> URL {
        guard let server, server.scheme == "https", server.host != nil, server.user == nil, server.password == nil else {
            #if DEBUG
            if let server, ["127.0.0.1", "localhost"].contains(server.host ?? ""), server.scheme == "http" { return server.appendingPathComponent(route) }
            #endif
            throw LicenseFailure("Activation isn’t available in this build yet.")
        }
        return server.appendingPathComponent(route)
    }
    private func request<T: Decodable>(_ route: String, body: [String: String] = [:]) async throws -> T {
        var request = URLRequest(url: try endpoint(route)); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let identity { request.setValue("Bearer \(identity.token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let serverError = try? JSONDecoder().decode(ServerFailure.self, from: data)
            throw LicenseFailure(serverError?.error ?? "Couldn’t verify access. Please try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func accept(_ received: LicenseGrant, key: String? = nil) throws {
        guard var saved = identity else { throw LicenseFailure("Missing activation identity.") }
        saved.activated = true
        saved.productKey = key ?? received.productKey ?? saved.productKey
        try vault.save(saved)
        identity = saved; productKey = saved.productKey
        grant = received; receivedAt = LicenseClock.seconds
        lastRefresh = receivedAt; updateAllowed()
    }
    func startTrial() async {
        await perform {
            let identity = try self.prepareIdentity()
            let received: LicenseGrant = try await self.request("v1/trial", body: ["device":identity.device,"token":identity.token])
            try self.accept(received)
            try await self.ensureRecoveryKey()
        }
    }
    func activate(_ key: String) async {
        await perform {
            let identity = try self.prepareIdentity()
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let received: LicenseGrant = try await self.request("v1/activate", body: ["device":identity.device,"token":identity.token,"productKey":normalized])
            try self.accept(received,key:normalized)
        }
    }
    func refresh() async {
        lastRefresh = LicenseClock.seconds
        await perform {
            if self.identity == nil { self.identity = try self.vault.load(); self.hasIdentity = self.identity != nil }
            guard self.identity != nil else { throw LicenseFailure("Start your free trial or enter a product key.") }
            let received: LicenseGrant = try await self.request("v1/entitlement")
            try self.accept(received)
            try await self.ensureRecoveryKey()
        }
    }
    private func ensureRecoveryKey() async throws {
        guard var saved = identity, saved.productKey == nil, grant?.status != "developer" else { return }
        let recovered: RecoveryKey = try await request("v1/recovery-key")
        saved.productKey = recovered.productKey
        try vault.save(saved); identity = saved; productKey = saved.productKey
    }
    private struct RecoveryKey: Decodable { let productKey: String }
    func openBilling(manage: Bool) async {
        await perform {
            let result: BillingLink = try await self.request(manage ? "v1/portal" : "v1/checkout")
            guard let url = URL(string: result.url), url.scheme == "https", ["checkout.stripe.com", "billing.stripe.com"].contains(url.host ?? "") else { throw LicenseFailure("The billing link could not be verified.") }
            NSWorkspace.shared.open(url)
        }
    }
    func copyProductKey() { guard let productKey else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(productKey, forType: .string); message = "Product key copied. Keep it private; it restores your Luma access." }
    var canCopyKey: Bool { productKey != nil }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false; updateAllowed() }
        do { try await operation() }
        catch let error as LicenseFailure { message = error.localizedDescription }
        catch { message = "Couldn’t reach the activation service. Check your connection and try again." }
    }
    private struct ServerFailure: Decodable { let error: String }
    private struct BillingLink: Decodable { let url: String }
}

struct LicenseFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct LicenseIdentity: Codable {
    let device: String
    let token: String
    var activated = false
    var productKey: String?
    static func make() throws -> Self {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { throw LicenseFailure("Couldn’t identify this Mac for the trial.") }
        defer { IOObjectRelease(entry) }
        guard let uuid = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { throw LicenseFailure("Couldn’t identify this Mac for the trial.") }
        let device = SHA256.hash(data: Data(("com.luma.licensing.v1|" + uuid).utf8)).map { String(format:"%02x",$0) }.joined()
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw LicenseFailure("Couldn’t create your activation identity.") }
        return Self(device:device,token:bytes.map { String(format:"%02x",$0) }.joined())
    }
}
struct LicenseVault {
    var service = "com.luma.license"
    private var query: [String: Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"activation"] }
    func load() throws -> LicenseIdentity? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?; let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data=result as? Data else { throw LicenseFailure("macOS Keychain could not load your activation.") }
        return try JSONDecoder().decode(LicenseIdentity.self,from:data)
    }
    func save(_ identity: LicenseIdentity) throws {
        let data=try JSONEncoder().encode(identity)
        var status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var q=query; q[kSecValueData as String]=data; q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status=SecItemAdd(q as CFDictionary,nil)
        }
        guard status == errSecSuccess else { throw LicenseFailure("macOS Keychain could not save your activation. Please try again.") }
    }
}

// Continuous monotonic time includes sleep and cannot be extended by changing the wall clock.
private enum LicenseClock {
    static var seconds: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
