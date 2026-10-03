//
//  Config.swift
//  XKitTests
//
//  Created by Kabir Oberai on 05/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XCTest
import XKit

struct Config: Decodable {
    struct AppleID: Decodable {
        let username: String
        let password: String
        /// for non-login tests, just provide a token already
        let token: DeveloperServicesLoginToken
    }

    let appleID: AppleID
    let deviceInfo: DeviceInfo
    let preferredTeam: String
    let udid: String

    static var current: Config {
        get throws {
            guard let url = Bundle.module.url(forResource: "config", withExtension: "json") else {
                throw XCTSkip("Add Tests/XKitTests/config/config.json to run the integration tests.")
            }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        }
    }
}
