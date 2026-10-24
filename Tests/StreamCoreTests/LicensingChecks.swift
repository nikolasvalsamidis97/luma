import Foundation
import StreamCore

extension StreamCoreChecks {
    func testLicensingLeases() throws {
        func grant(_ status: String, until: Double = 1300, access: Double = 2000) throws -> LicenseGrant {
            let data = try JSONSerialization.data(withJSONObject: ["status":status,"serverTime":1000,"validUntil":until,"accessUntil":access,"trialEndsAt":2000,"billingAvailable":true,"hasSubscription":false,"priceLabel":"€4/month"])
            return try JSONDecoder().decode(LicenseGrant.self,from:data)
        }
        for status in ["trial","active","developer"] {
            let value = try grant(status)
            precondition(value.permitsPlayback(receivedAt: 400,currentUptime: 699))
            precondition(!value.permitsPlayback(receivedAt: 400,currentUptime: 700))
            precondition(!value.permitsPlayback(receivedAt: 400,currentUptime: 399))
        }
        for status in ["expired","unpaid","unknown",""] { let value = try grant(status); precondition(value.leaseDuration == 0) }
        let capped = try grant("trial",until:5000)
        let short = try grant("trial",until:1010)
        let paid = try grant("active",until:1300,access:1001)
        let expired = try grant("trial",until:999)
        precondition(capped.leaseDuration == 300 && short.leaseDuration == 10 && paid.leaseDuration == 1 && expired.leaseDuration == 0)
    }
}
