//
//  DeveloperServicesFetchProfileOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils
import DeveloperAPI

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public enum Errors: LocalizedError {
        case bundleIDNotFound(String)
        case tooManyMatchingBundleIDs(String)
        case noRegisteredDevices(String)
        case invalidProfileData

        public var errorDescription: String? {
            switch self {
            case .bundleIDNotFound(let bundleID):
                return "Could not find App ID '\(bundleID)' in Apple Developer services."
            case .tooManyMatchingBundleIDs(let bundleID):
                return "Multiple App IDs matched '\(bundleID)'."
            case .noRegisteredDevices(let platform):
                return "No enabled \(platform) devices are available for provisioning."
            case .invalidProfileData:
                return "Apple Developer services returned invalid provisioning profile data."
            }
        }
    }

    public let context: SigningContext
    public let bundleID: String
    public let signingInfo: SigningInfo
    public let platform: ProvisioningPlatform
    public init(
        context: SigningContext,
        bundleID: String,
        signingInfo: SigningInfo,
        platform: ProvisioningPlatform = .iOS
    ) {
        self.context = context
        self.bundleID = bundleID
        self.signingInfo = signingInfo
        self.platform = platform
    }

    public func perform() async throws -> Mobileprovision {
        let bundleID = try await fetchBundleIDWithRetry()

        let profiles = bundleID.relationships?.profiles?.data ?? []
        switch profiles.count {
        case 0:
            // we're good
            break
        case 1:
            _ = try await context.developerAPIClient.profilesDeleteInstance(path: .init(id: profiles[0].id)).noContent
        default:
            // if the user has >1 profile, it's probably okay to add another one (acceptable for non-free accounts?)
            break
        }

        let serialNumber = signingInfo.certificate.serialNumber()
        let certs = try await context.developerAPIClient.certificatesGetCollection(
            query: .init(
                filter_lbrack_serialNumber_rbrack_: [serialNumber]
            )
        )
        .ok.body.json.data

        let allDevices = try await DeveloperAPIPages {
            try await context.developerAPIClient.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)
        let preferredDeviceUDID = try expectedDeviceUDID()
        let matchingDevices = allDevices.filter { device in
            guard device.attributes?.status?.value1 == .enabled else {
                return false
            }
            if let preferredDeviceUDID {
                return device.attributes?.udid?.uppercased() == preferredDeviceUDID
            }
            if let devicePlatform = device.attributes?.platform?.value1 {
                return platform.supports(devicePlatform: devicePlatform)
            }
            // Older/unexpected responses may omit the platform field.
            if let deviceClass = device.attributes?.deviceClass?.value1 {
                return platform.supports(deviceClass: deviceClass)
            }
            return false
        }

        guard !matchingDevices.isEmpty else {
            throw Errors.noRegisteredDevices(platform.displayName)
        }

        let devicesRelationship: Components.Schemas.ProfileCreateRequest.DataPayload.RelationshipsPayload
            .DevicesPayload = .init(data: matchingDevices.map { .init(_type: .devices, id: $0.id) })

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: "XTL profile \(bundleID.id)",
                            profileType: .init(platform.profileType)
                        ),
                        relationships: .init(
                            bundleId: .init(
                                data: .init(_type: .bundleIds, id: bundleID.id)
                            ),
                            devices: devicesRelationship,
                            certificates: .init(data: certs.map {
                                .init(_type: .certificates, id: $0.id)
                            })
                        )
                    )
                )
            )
        )
        .created.body.json.data

        guard let contentString = response.attributes?.profileContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Errors.invalidProfileData }

        return try Mobileprovision(data: contentData)
    }

    private func fetchBundleIDWithRetry() async throws -> Components.Schemas.BundleId {
        let maxAttempts = 6
        var lastNotFound = false

        for attempt in 1 ... maxAttempts {
            let bundleIDs = try await context.developerAPIClient
                .bundleIdsGetCollection(query: .init(
                    filter_lbrack_identifier_rbrack_: [bundleID],
                    fields_lbrack_profiles_rbrack_: [.bundleId],
                    include: [.profiles]
                ))
                .ok.body.json

            // filter[identifier] is a prefix filter so we need to manually upgrade to equality
            let filtered = bundleIDs.data.filter { candidate in
                guard candidate.attributes?.identifier == bundleID else {
                    return false
                }
                guard let platformValue = candidate.attributes?.platform?.value1 else {
                    return true
                }
                return platform.supports(devicePlatform: platformValue)
            }

            switch filtered.count {
            case 1:
                return filtered[0]
            case 0:
                lastNotFound = true
            default:
                throw Errors.tooManyMatchingBundleIDs(bundleID)
            }

            if attempt < maxAttempts {
                try await Task.sleep(for: .seconds(1))
            }
        }

        if lastNotFound {
            throw Errors.bundleIDNotFound(bundleID)
        }
        throw Errors.tooManyMatchingBundleIDs(bundleID)
    }

    private func expectedDeviceUDID() throws -> String? {
        switch platform {
        case .iOS:
            return context.targetDevice?.udid.uppercased()
        case .macOS:
            #if os(macOS)
            return try currentMacProvisioningUDID()
            #else
            return nil
            #endif
        }
    }

    #if os(macOS)
    private func currentMacProvisioningUDID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }

        let marker = "Provisioning UDID:"
        if let markerRange = output.range(of: marker) {
            let suffix = output[markerRange.upperBound...]
            let udid = suffix
                .prefix { $0 != "\n" && $0 != "\r" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !udid.isEmpty {
                return udid.uppercased()
            }
        }

        return try currentMacHardwareUUID()
    }

    private func currentMacHardwareUUID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }

        let marker = "\"IOPlatformUUID\" = \""
        guard let markerRange = output.range(of: marker) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let suffix = output[markerRange.upperBound...]
        guard let endQuote = suffix.firstIndex(of: "\"") else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let uuid = String(suffix[..<endQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uuid.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return uuid.uppercased()
    }
    #endif

}
