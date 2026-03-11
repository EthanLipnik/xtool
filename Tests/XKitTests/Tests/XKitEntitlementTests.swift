import XCTest
@testable import XKit

final class XKitEntitlementTests: XCTestCase {
    func testAssociatedDomainsAndNetworkExtensionRoundTrip() throws {
        let original = try Entitlements(entitlements: [
            AssociatedDomainsEntitlement(rawValue: ["applinks:example.com"]),
            NetworkExtensionEntitlement(rawValue: true),
        ])

        let data = try PropertyListEncoder().encode(original)
        let decoded = try PropertyListDecoder().decode(Entitlements.self, from: data)
        let parsed = try decoded.entitlements()

        let associatedDomains = try XCTUnwrap(parsed.first { $0 is AssociatedDomainsEntitlement } as? AssociatedDomainsEntitlement)
        XCTAssertEqual(associatedDomains.rawValue, ["applinks:example.com"])
        XCTAssertEqual(associatedDomains.anyCapability?.capabilityType.value1, .associatedDomains)

        let networkExtension = try XCTUnwrap(parsed.first { $0 is NetworkExtensionEntitlement } as? NetworkExtensionEntitlement)
        XCTAssertTrue(networkExtension.rawValue)
        XCTAssertEqual(networkExtension.anyCapability?.capabilityType.value1, .networkExtensions)
    }
}
