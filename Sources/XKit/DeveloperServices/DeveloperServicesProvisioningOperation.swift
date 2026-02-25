//
//  DeveloperServicesProvisioningOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 12/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

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
        status("Registering \(platform.displayName) device…")
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

}
