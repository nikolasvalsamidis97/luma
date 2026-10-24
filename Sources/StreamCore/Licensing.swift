import Foundation

public struct LicenseGrant: Codable, Equatable {
    public let status: String
    public let serverTime: Double
    public let validUntil: Double
    public let accessUntil: Double
    public let trialEndsAt: Double
    public let billingAvailable: Bool
    public let hasSubscription: Bool
    public let priceLabel: String
    public let productKey: String?
    public var leaseDuration: TimeInterval {
        guard ["trial", "active", "developer"].contains(status), serverTime.isFinite,
              validUntil.isFinite, accessUntil.isFinite else { return 0 }
        return max(0, min(300, min(validUntil, accessUntil) - serverTime))
    }
    public func permitsPlayback(receivedAt uptime: TimeInterval, currentUptime: TimeInterval) -> Bool {
        let elapsed = currentUptime - uptime
        return elapsed >= 0 && elapsed < leaseDuration
    }
}
