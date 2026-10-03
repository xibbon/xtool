//
//  DeveloperServicesTestClient.swift
//  XKitTests
//
//  Created by Kabir Oberai on 06/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XCTest
import Dependencies
@testable import XKit

#if false

extension TCPAnisetteDataProvider {

    static func test() -> TCPAnisetteDataProvider {
        TCPAnisetteDataProvider(localPort: 4321)
    }

}

extension NetcatAnisetteDataProvider {

    static func test() -> NetcatAnisetteDataProvider {
        NetcatAnisetteDataProvider(localPort: 4322, deviceInfo: Config.current.deviceInfo)
    }

}

#endif

private func withIntegrationDependencies<Result>(
    storage: KeyValueStorage,
    operation: () -> Result
) throws -> Result {
    let config = try Config.current
    return withDependencies {
        $0.context = .live
        $0.keyValueStorage = storage
        $0.deviceInfoProvider = DeviceInfoProvider { config.deviceInfo }
    } operation: {
        withDependencies {
            $0.anisetteDataProvider = ADIDataProvider()
        } operation: {
            operation()
        }
    }
}

extension GrandSlamClient {

    static func test(storage: KeyValueStorage) throws -> GrandSlamClient {
        try withIntegrationDependencies(storage: storage) {
            GrandSlamClient()
        }
    }

}

extension DeveloperServicesClient {

    static func test(storage: KeyValueStorage) throws -> DeveloperServicesClient {
        let config = try Config.current
        return try withIntegrationDependencies(storage: storage) {
            DeveloperServicesClient(loginToken: config.appleID.token)
        }
    }

}
