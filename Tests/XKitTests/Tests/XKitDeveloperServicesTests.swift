//
//  XKitDeveloperServicesTests.swift
//  XKitTests
//
//  Created by Kabir Oberai on 30/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import XCTest
import SuperutilsTestSupport
import XKit

// swiftlint:disable force_try

class XKitDeveloperServicesTests: XCTestCase {

    var storage: KeyValueStorage!
    var client: DeveloperServicesClient!

    override func setUp() {
        super.setUp()
        _ = addMockSigner
        storage = MemoryKeyValueStorage()
        client = try! .test(storage: storage)
    }

    override func tearDown() {
        super.tearDown()
        client = nil
    }

    // integration test for provisioning
    @MainActor func testProvisioningIntegration() async throws {
        try await withIntegrationDependencies(storage: storage) { [self] in
            let listTeams = DeveloperServicesListTeamsRequest()
            let teams = try await self.client.send(listTeams)
            let team = teams.first { $0.status == "active" && $0.memberships.contains { $0.platform == .iOS } }!

            let source = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "app"))

            let context = try XCTTry(SigningContext(
                auth: .xcode(.init(
                    loginToken: Config.current.appleID.token,
                    teamID: team.id
                )),
                targetDevice: .init(
                    udid: Config.current.udid,
                    name: SigningContext.hostName
                )
            ))

            let response = try await DeveloperServicesProvisioningOperation(
                context: context,
                app: source,
                confirmRevocation: { _ in true },
                progress: { _ in }
            ).perform()
            print(response)
        }
    }

    @MainActor func testListTeams() async throws {
        try await withIntegrationDependencies(storage: storage) { [self] in
            let listTeams = DeveloperServicesListTeamsRequest()
            let teams = try await self.client.send(listTeams)
            XCTAssertFalse(teams.isEmpty, "No teams found")

            let team = try XCTUnwrap(
                teams.first { $0.id.rawValue == Config.current.preferredTeam },
                "Could not find preferred team"
            )

            XCTAssertEqual(team.status, "active", "Expected team status active. Got: \(team.status)")
            XCTAssert(team.memberships.contains { $0.platform == .iOS }, "Team does not have iOS membership")
        }
    }

}
