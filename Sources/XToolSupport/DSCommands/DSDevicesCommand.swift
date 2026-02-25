import Foundation
import ArgumentParser
import XKit
import DeveloperAPI

struct DSDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Interact with devices",
        subcommands: [
            DSDevicesListCommand.self,
            DSDevicesRegisterThisMacCommand.self,
        ],
        defaultSubcommand: DSDevicesListCommand.self
    )
}

struct DSDevicesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List devices"
    )

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())

        let devices = try await DeveloperAPIPages {
            try await client.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        for device in devices {
            print("- id: \(device.id)")
            guard let attributes = device.attributes else {
                continue
            }

            if let name = attributes.name {
                print("  name: \(name)")
            }

            if let platform = attributes.platform {
                print("  platform: \(platform.rawValue)")
            }

            if let udid = attributes.udid {
                print("  udid: \(udid)")
            }

            if let deviceClass = attributes.deviceClass {
                print("  device class: \(deviceClass.rawValue)")
            }

            if let status = attributes.status {
                print("  status: \(status.rawValue)")
            }

            if let model = attributes.model {
                print("  model: \(model)")
            }

            if let addedDate = attributes.addedDate {
                print("  added date: \(addedDate.formatted(.dateTime))")
            }
        }
    }
}

struct DSDevicesRegisterThisMacCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register-this-mac",
        abstract: "Register the current Mac for Developer Services provisioning"
    )

    func run() async throws {
        #if os(macOS)
        let auth = try AuthToken.saved().authData()
        let context = try SigningContext(auth: auth)
        try await DeveloperServicesAddDeviceOperation(
            context: context,
            platform: .macOS
        ).perform()
        print("Current Mac is available for macOS provisioning.")
        #else
        throw Console.Error("This command is only available on macOS.")
        #endif
    }
}
