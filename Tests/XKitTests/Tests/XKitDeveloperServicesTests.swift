//
//  XKitDeveloperServicesTests.swift
//  XKitTests
//
//  Created by Kabir Oberai on 30/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import XCTest
import SuperutilsTestSupport
import Dependencies
@testable import XKit

// swiftlint:disable force_try

class XKitDeveloperServicesTests: XCTestCase {

    var storage: KeyValueStorage!
    var client: DeveloperServicesClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = addMockSigner
        storage = MemoryKeyValueStorage()
        client = try .test(storage: storage)
    }

    override func tearDown() {
        super.tearDown()
        client = nil
    }

    // integration test for provisioning
    @MainActor func testProvisioningIntegration() async throws {
        guard let source = Bundle.module.url(forResource: "test", withExtension: "app") else {
            throw XCTSkip("Add Tests/XKitTests/config/test.app to run the provisioning integration test.")
        }
        let listTeams = DeveloperServicesListTeamsRequest()
        let teams = try await client.send(listTeams)
        let team = teams.first { $0.status == "active" && $0.memberships.contains { $0.platform == .iOS } }!

        let config = try Config.current
        let context = try SigningContext(
            auth: .xcode(.init(loginToken: config.appleID.token, teamID: team.id)),
            targetDevice: .init(udid: config.udid, name: SigningContext.hostName)
        )

        let response = try await withDependencies {
            $0.context = .live
            $0.keyValueStorage = storage
            $0.deviceInfoProvider = client.deviceInfoProvider
            $0.anisetteDataProvider = client.anisetteDataProvider
            $0.signingInfoManager = MemoryBackedSigningInfoManager()
        } operation: {
            try await DeveloperServicesProvisioningOperation(
                context: context,
                app: source,
                confirmRevocation: { _ in true },
                progress: { _ in }
            ).perform()
        }
        print(response)
    }

    func testListTeams() async throws {
        let listTeams = DeveloperServicesListTeamsRequest()
        let teams = try await client.send(listTeams)
        XCTAssertFalse(teams.isEmpty, "No teams found")
        let preferredTeam = try Config.current.preferredTeam

        let team = try XCTUnwrap(
            teams.first { $0.id.rawValue == preferredTeam },
            "Could not find preferred team"
        )

        XCTAssertEqual(team.status, "active", "Expected team status active. Got: \(team.status)")
        XCTAssert(team.memberships.contains { $0.platform == .iOS }, "Team does not have iOS membership")
    }

}
