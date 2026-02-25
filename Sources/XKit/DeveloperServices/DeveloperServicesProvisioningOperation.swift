//
//  DeveloperServicesProvisioningOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Dependencies

public struct ProvisioningInfo: Sendable {
    public let newBundleID: String
    public let entitlements: Entitlements
    public let mobileprovision: Mobileprovision
}

public struct DeveloperServicesProvisioningOperation: DeveloperServicesOperation {

    public struct Response {
        public let signingInfo: SigningInfo
        public let provisioningDict: [URL: ProvisioningInfo]
    }

    public let context: SigningContext
    public let app: URL
    public let confirmRevocation: @Sendable ([DeveloperServicesCertificate]) async -> Bool
    public let progress: @Sendable (Double) -> Void
    public let status: @Sendable (String) -> Void
    @Dependency(\.signingInfoManager) private var signingInfoManager
    @Dependency(\.keyValueStorage) private var keyValueStorage
    @Dependency(\.persistentDirectory) private var persistentDirectory
    public init(
        context: SigningContext,
        app: URL,
        confirmRevocation: @escaping @Sendable ([DeveloperServicesCertificate]) async -> Bool,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.context = context
        self.app = app
        self.confirmRevocation = confirmRevocation
        self.progress = progress
        self.status = status
    }

    public func perform() async throws -> Response {
        let platform = ProvisioningPlatform(appBundleURL: app)

        progress(0/3)
        if let signingInfo = signingInfoManager[context.auth.identityID],
           let provisioningDict = try await cachedProvisioningIfValid(signingInfo: signingInfo) {
            status("Using cached signing assets…")
            progress(3/3)
            return .init(signingInfo: signingInfo, provisioningDict: provisioningDict)
        }

        status("Checking \(platform.displayName) device registration…")
        do {
            try await DeveloperServicesAddDeviceOperation(
                context: context,
                platform: platform
            ).perform()
        } catch {
            guard shouldContinueAfterRegistrationError(error) else {
                throw error
            }
            // Device registration can fail transiently or return malformed
            // middleware errors even when the device is already registered.
            // Continue to provisioning and let profile creation retries decide.
            status(registrationFallbackStatus(for: error))
        }

        progress(1/3)
        status("Preparing signing certificate…")
        let signingInfo = try await DeveloperServicesFetchCertificateOperation(
            context: self.context,
            confirmRevocation: confirmRevocation
        ).perform()

        progress(2/3)
        status("Creating provisioning profile…")

        let maxProvisioningAttempts = 4
        var lastError: Error?
        var provisioningDict: [URL: ProvisioningInfo] = [:]

        for attempt in 1 ... maxProvisioningAttempts {
            do {
                provisioningDict = try await DeveloperServicesAddAppOperation(
                    context: context,
                    signingInfo: signingInfo,
                    root: app,
                    platform: platform
                ).perform()
                lastError = nil
                break
            } catch {
                lastError = error
                guard attempt < maxProvisioningAttempts,
                      shouldRetryProvisioning(error: error, platform: platform)
                else {
                    throw error
                }

                status(
                    "Waiting for \(platform.displayName) device registration to propagate " +
                        "(attempt \(attempt + 1)/\(maxProvisioningAttempts))…"
                )

                do {
                    try await DeveloperServicesAddDeviceOperation(
                        context: context,
                        platform: platform
                    ).perform()
                } catch {
                    // Ignore device-registration retry errors and let profile creation retry decide.
                }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }

        if let lastError {
            throw lastError
        }

        // Persist profiles for offline/fast subsequent deploys.
        do {
            try persistProvisioningCache(for: provisioningDict)
        } catch {
            // Best effort only; provisioning succeeded so this should not fail the deploy.
        }

        progress(3/3)
        return .init(signingInfo: signingInfo, provisioningDict: provisioningDict)
    }

    private func shouldRetryProvisioning(
        error: Error,
        platform: ProvisioningPlatform
    ) -> Bool {
        if let profileError = error as? DeveloperServicesFetchProfileOperation.Errors {
            switch profileError {
            case .noRegisteredDevices, .bundleIDNotFound:
                return true
            default:
                break
            }
        }
        let message = String(describing: error).lowercased()
        if message.contains("no current") && message.contains("devices") {
            switch platform {
            case .macOS:
                return message.contains("mac_os") || message.contains("macos")
            case .iOS:
                return message.contains("ios")
            }
        }
        return false
    }

    private func shouldContinueAfterRegistrationError(_ error: Error) -> Bool {
        if error is DeveloperServicesAddDeviceOperation.Errors {
            return true
        }

        let message = String(describing: error).lowercased()
        return message.contains("devices_createinstance")
            || message.contains("middleware of type 'developerapixcodeauthmiddleware'")
            || message.contains("client encountered an error invoking the operation")
            || message.contains("could not connect to the server")
            || message.contains("isn’t in the correct format")
            || message.contains("isn't in the correct format")
    }

    private func registrationFallbackStatus(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "Device registration check failed. Continuing with existing registered devices."
    }

    private func cachedProvisioningIfValid(
        signingInfo: SigningInfo
    ) async throws -> [URL: ProvisioningInfo]? {
        let appBundles = appBundleURLs(root: app)
        var provisioning: [URL: ProvisioningInfo] = [:]
        for bundleURL in appBundles {
            guard let info = try await cachedProvisioningInfo(
                for: bundleURL,
                signingInfo: signingInfo
            ) else {
                return nil
            }
            provisioning[bundleURL] = info
        }
        return provisioning
    }

    private func appBundleURLs(root: URL) -> [URL] {
        var bundles: [URL] = [root]
        for pluginsDir in ["PlugIns", "Extensions", "Contents/PlugIns", "Contents/Extensions"] {
            let plugins = root.appendingPathComponent(pluginsDir)
            guard plugins.dirExists else { continue }
            bundles += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }
        return bundles
    }

    private func cachedProvisioningInfo(
        for bundleURL: URL,
        signingInfo: SigningInfo
    ) async throws -> ProvisioningInfo? {
        let platform = ProvisioningPlatform(appBundleURL: bundleURL)
        let infoPlistURL = self.infoPlistURL(for: bundleURL)

        guard let infoPlistData = try? Data(contentsOf: infoPlistURL),
              let infoPlist = try? PropertyListSerialization.propertyList(
                  from: infoPlistData,
                  format: nil
              ) as? [String: Any],
              let bundleID = infoPlist["CFBundleIdentifier"] as? String,
              let executableName = infoPlist["CFBundleExecutable"] as? String
        else {
            return nil
        }

        let expectedUDID = try expectedDeviceUDID(for: platform)
        let newBundleID = ProvisioningIdentifiers.identifier(
            fromSanitized: bundleID,
            context: context
        )
        let teamID = try signingInfo.certificate.teamID()

        var entitlements = try await loadEntitlements(
            for: bundleURL,
            executableName: executableName
        )
        try entitlements.update(teamID: .init(rawValue: teamID), bundleID: newBundleID)

        if platform == .macOS {
            try entitlements.updateEntitlements { ents in
                ents.removeAll {
                    $0 is ApplicationIdentifierEntitlement
                        || $0 is MacApplicationIdentifierEntitlement
                        || $0 is GetTaskAllowEntitlement
                        || $0 is MacGetTaskAllowEntitlement
                        || $0 is KeychainAccessGroupsEntitlement
                }
                ents.append(MacApplicationIdentifierEntitlement(rawValue: "\(teamID).\(newBundleID)"))
                ents.append(MacGetTaskAllowEntitlement(rawValue: true))
                ents.append(KeychainAccessGroupsEntitlement(rawValue: ["\(teamID).*"]))
            }
        } else {
            try entitlements.updateEntitlements { ents in
                if let index = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                    ents[index] = GetTaskAllowEntitlement(rawValue: true)
                } else {
                    ents.append(GetTaskAllowEntitlement(rawValue: true))
                }
            }
        }

        for candidate in try provisioningCandidates(
            for: bundleURL,
            originalBundleID: bundleID,
            platform: platform,
            expectedDeviceUDID: expectedUDID
        ) {
            guard let mobileprovision = try? Mobileprovision(data: candidate.data),
                  let digest = try? mobileprovision.digest()
            else {
                continue
            }

            guard digest.expirationDate > Date() else {
                continue
            }

            let certificateSerial = signingInfo.certificate.serialNumber().uppercased()
            guard digest.certificates.contains(where: { $0.serialNumber().uppercased() == certificateSerial }) else {
                continue
            }

            if let expectedUDID {
                let hasDevice = digest.devices.contains { $0.uppercased() == expectedUDID }
                guard hasDevice else {
                    continue
                }
            }

            guard try entitlementsAreCompatible(required: entitlements, provisioned: digest.entitlements) else {
                continue
            }

            return ProvisioningInfo(
                newBundleID: newBundleID,
                entitlements: entitlements,
                mobileprovision: mobileprovision
            )
        }
        return nil
    }

    private enum ProvisioningCandidateSource {
        case embedded
        case cached
    }

    private struct ProvisioningCandidate {
        let source: ProvisioningCandidateSource
        let data: Data
    }

    private func provisioningCandidates(
        for bundleURL: URL,
        originalBundleID: String,
        platform: ProvisioningPlatform,
        expectedDeviceUDID: String?
    ) throws -> [ProvisioningCandidate] {
        var candidates: [ProvisioningCandidate] = []

        let embeddedProfileURL = bundleURL.appendingPathComponent(platform.embeddedProvisioningProfileRelativePath)
        if let profileData = try? Data(contentsOf: embeddedProfileURL), !profileData.isEmpty {
            candidates.append(.init(source: .embedded, data: profileData))
        }

        let cacheKeys = provisioningCacheKeys(
            originalBundleID: originalBundleID,
            platform: platform,
            expectedDeviceUDID: expectedDeviceUDID
        )
        for cacheKey in cacheKeys {
            if let cachedData = try cachedProvisioningData(forKey: cacheKey),
               !cachedData.isEmpty,
               !candidates.contains(where: { $0.data == cachedData }) {
                candidates.append(.init(source: .cached, data: cachedData))
            }
        }

        return candidates
    }

    private func persistProvisioningCache(
        for provisioningDict: [URL: ProvisioningInfo]
    ) throws {
        for (bundleURL, provisioningInfo) in provisioningDict {
            let platform = ProvisioningPlatform(appBundleURL: bundleURL)
            let infoPlistURL = self.infoPlistURL(for: bundleURL)

            guard let infoPlistData = try? Data(contentsOf: infoPlistURL),
                  let infoPlist = try? PropertyListSerialization.propertyList(
                      from: infoPlistData,
                      format: nil
                  ) as? [String: Any],
                  let originalBundleID = infoPlist["CFBundleIdentifier"] as? String
            else {
                continue
            }

            let expectedUDID = try? expectedDeviceUDID(for: platform)
            let profileData = try provisioningInfo.mobileprovision.data()
            let cacheKeys = provisioningCacheKeys(
                originalBundleID: originalBundleID,
                platform: platform,
                expectedDeviceUDID: expectedUDID
            )
            for cacheKey in cacheKeys {
                try persistProvisioningData(profileData, forKey: cacheKey)
            }
        }
    }

    private func provisioningCacheKeys(
        originalBundleID: String,
        platform: ProvisioningPlatform,
        expectedDeviceUDID: String?
    ) -> [String] {
        let sanitizedBundleID = ProvisioningIdentifiers.sanitize(identifier: originalBundleID)
        let prefixedBundleID = ProvisioningIdentifiers.identifier(
            fromSanitized: sanitizedBundleID,
            context: context
        )

        let bundleCandidates = uniqueValues([originalBundleID, sanitizedBundleID, prefixedBundleID])

        var deviceCandidates = ["no-device"]
        if let expectedDeviceUDID, !expectedDeviceUDID.isEmpty {
            deviceCandidates.insert(expectedDeviceUDID.uppercased(), at: 0)
        }

        var keys: [String] = []
        for bundleCandidate in bundleCandidates {
            for deviceCandidate in deviceCandidates {
                keys.append(
                    provisioningCacheKey(
                        originalBundleID: bundleCandidate,
                        platform: platform,
                        devicePart: deviceCandidate
                    )
                )
            }
        }

        return uniqueValues(keys)
    }

    private func provisioningCacheKey(
        originalBundleID: String,
        platform: ProvisioningPlatform,
        devicePart: String
    ) -> String {
        let platformPart: String = switch platform {
        case .iOS:
            "ios"
        case .macOS:
            "macos"
        }
        return "provisioning-cache/v1/\(sanitizeCacheComponent(context.auth.identityID))/\(platformPart)/\(sanitizeCacheComponent(devicePart))/\(sanitizeCacheComponent(originalBundleID))"
    }

    private func cachedProvisioningData(forKey cacheKey: String) throws -> Data? {
        if let cachedData = try keyValueStorage.data(forKey: cacheKey),
           !cachedData.isEmpty {
            return cachedData
        }

        let diskURL = provisioningDiskCacheURL(forKey: cacheKey)
        if let diskData = try? Data(contentsOf: diskURL),
           !diskData.isEmpty {
            return diskData
        }

        return nil
    }

    private func persistProvisioningData(_ data: Data, forKey cacheKey: String) throws {
        var storageError: Error?
        var diskError: Error?

        do {
            try keyValueStorage.setData(data, forKey: cacheKey)
        } catch {
            storageError = error
        }

        do {
            let diskURL = provisioningDiskCacheURL(forKey: cacheKey)
            try FileManager.default.createDirectory(
                at: diskURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: diskURL, options: .atomic)
        } catch {
            diskError = error
        }

        if storageError != nil, let diskError {
            throw diskError
        }
    }

    private func provisioningDiskCacheURL(forKey cacheKey: String) -> URL {
        let fileName = sanitizeCacheComponent(
            cacheKey
                .replacingOccurrences(of: "/", with: "__")
                .replacingOccurrences(of: ".", with: "_")
        )
        return persistentDirectory
            .appendingPathComponent("provisioning-cache", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private func sanitizeCacheComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        unique.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            unique.append(value)
        }
        return unique
    }

    private func infoPlistURL(for app: URL) -> URL {
        let macInfoPlist = app.appendingPathComponent("Contents").appendingPathComponent("Info.plist")
        if FileManager.default.fileExists(atPath: macInfoPlist.path) {
            return macInfoPlist
        }
        return app.appendingPathComponent("Info.plist")
    }

    private func executableURL(for app: URL, executableName: String) -> URL {
        let macExecutable = app
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(executableName)
        if FileManager.default.fileExists(atPath: macExecutable.path) {
            return macExecutable
        }
        return app.appendingPathComponent(executableName)
    }

    private func sidecarEntitlementsURLs(for app: URL) -> [URL] {
        [
            app.appendingPathComponent("archived-expanded-entitlements.xcent"),
            app.appendingPathComponent("Contents").appendingPathComponent("archived-expanded-entitlements.xcent")
        ]
    }

    private func readEntitlements(at url: URL) -> Entitlements? {
        guard let entitlementsData = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData)
    }

    private func loadEntitlements(
        for app: URL,
        executableName: String
    ) async throws -> Entitlements {
        for sidecarURL in sidecarEntitlementsURLs(for: app) where FileManager.default.fileExists(atPath: sidecarURL.path) {
            if let sidecarEntitlements = readEntitlements(at: sidecarURL) {
                return sidecarEntitlements
            }
        }

        let executableURL = executableURL(for: app, executableName: executableName)
        if let entitlementsData = try? await context.signer.analyze(executable: executableURL),
           let analyzedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            return analyzedEntitlements
        }

        return try Entitlements(entitlements: [])
    }

    private func entitlementsAreCompatible(
        required: Entitlements,
        provisioned: Entitlements
    ) throws -> Bool {
        let requiredDict = try entitlementDictionary(required)
        let provisionedDict = try entitlementDictionary(provisioned)

        for (key, requiredValue) in requiredDict {
            guard let provisionedValue = provisionedDict[key] else {
                return false
            }

            if key == ApplicationIdentifierEntitlement.identifier
                || key == MacApplicationIdentifierEntitlement.identifier {
                guard bundleIdentifierValueMatches(required: requiredValue, provisioned: provisionedValue) else {
                    return false
                }
                continue
            }

            if key == KeychainAccessGroupsEntitlement.identifier {
                guard keychainGroupsMatch(required: requiredValue, provisioned: provisionedValue) else {
                    return false
                }
                continue
            }

            guard plistValuesMatch(requiredValue, provisionedValue) else {
                return false
            }
        }

        return true
    }

    private func entitlementDictionary(_ entitlements: Entitlements) throws -> [String: Any] {
        let data = try PropertyListEncoder().encode(entitlements)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any] ?? [:]
    }

    private func bundleIdentifierValueMatches(required: Any, provisioned: Any) -> Bool {
        guard let requiredID = required as? String,
              let provisionedID = provisioned as? String else {
            return false
        }
        if requiredID == provisionedID {
            return true
        }
        if provisionedID.hasSuffix(".*") {
            let wildcardPrefix = String(provisionedID.dropLast(2))
            return requiredID == wildcardPrefix || requiredID.hasPrefix("\(wildcardPrefix).")
        }
        return false
    }

    private func keychainGroupsMatch(required: Any, provisioned: Any) -> Bool {
        guard let requiredGroups = required as? [String],
              let provisionedGroups = provisioned as? [String] else {
            return false
        }
        return requiredGroups.allSatisfy { requiredGroup in
            provisionedGroups.contains { provisionedGroup in
                if requiredGroup == provisionedGroup {
                    return true
                }
                if provisionedGroup.hasSuffix(".*") {
                    let wildcardPrefix = String(provisionedGroup.dropLast(2))
                    return requiredGroup == wildcardPrefix || requiredGroup.hasPrefix("\(wildcardPrefix).")
                }
                return false
            }
        }
    }

    private func plistValuesMatch(_ required: Any, _ provisioned: Any) -> Bool {
        switch (required, provisioned) {
        case let (requiredDict as [String: Any], provisionedDict as [String: Any]):
            guard requiredDict.count == provisionedDict.count else {
                return false
            }
            for (key, requiredValue) in requiredDict {
                guard let provisionedValue = provisionedDict[key],
                      plistValuesMatch(requiredValue, provisionedValue) else {
                    return false
                }
            }
            return true
        case let (requiredArray as [Any], provisionedArray as [Any]):
            if let requiredStrings = requiredArray as? [String],
               let provisionedStrings = provisionedArray as? [String] {
                return requiredStrings.sorted() == provisionedStrings.sorted()
            }
            guard requiredArray.count == provisionedArray.count else {
                return false
            }
            return zip(requiredArray, provisionedArray).allSatisfy(plistValuesMatch)
        default:
            return (required as AnyObject).isEqual(provisioned)
        }
    }

    private func expectedDeviceUDID(
        for platform: ProvisioningPlatform
    ) throws -> String? {
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
