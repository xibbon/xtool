import Foundation
import DeveloperAPI

public struct DeveloperServicesAddDeviceOperation: DeveloperServicesOperation {
    public enum Errors: LocalizedError {
        case deviceNotAvailable(udid: String, platform: String)

        public var errorDescription: String? {
            switch self {
            case .deviceNotAvailable(let udid, let platform):
                return "Device \(udid) is not available for \(platform) provisioning yet."
            }
        }
    }

    public let context: SigningContext
    public let platform: ProvisioningPlatform

    public init(
        context: SigningContext,
        platform: ProvisioningPlatform = .iOS
    ) {
        self.context = context
        self.platform = platform
    }

    public func perform() async throws {
        guard let targetDevice = try resolveTargetDevice() else { return }
        let normalizedUDID = targetDevice.udid.uppercased()

        // Device registration is idempotent: if the device is already present and enabled,
        // skip createInstance entirely to avoid unnecessary API conflicts.
        if let existingDevice = try await findRegisteredDevice(udid: normalizedUDID) {
            if existingDevice.attributes?.status?.value1 == .enabled {
                return
            }
            if existingDevice.attributes?.status?.value1 == .disabled {
                await tryEnableDevice(existingDevice)
            }
            try await waitForDeviceAvailability(udid: normalizedUDID)
            return
        }

        // try to register the device
        let response = try await context.developerAPIClient.devicesCreateInstance(
            body: .json(.init(data: .init(
                _type: .devices,
                attributes: .init(
                    name: targetDevice.name,
                    platform: .init(platform.bundleIDPlatform),
                    udid: normalizedUDID
                )
            )))
        )

        // we get a 409 CONFLICT if the device was already registered.
        // handle this by returning gracefully.
        if (try? response.conflict) != nil {
            try await waitForDeviceAvailability(udid: normalizedUDID)
            return
        }

        // otherwise, we should get a 201 CREATED to indicate that the device
        // was added. any other case is unexpected, and this will throw.
        _ = try response.created
        try await waitForDeviceAvailability(udid: normalizedUDID)
    }

    private func findRegisteredDevice(udid: String) async throws -> Components.Schemas.Device? {
        let pages = DeveloperAPIPages {
            try await context.developerAPIClient.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }

        for try await page in pages {
            if let matchingDevice = page.data.first(where: { device in
                device.attributes?.udid?.uppercased() == udid
            }) {
                return matchingDevice
            }
        }

        return nil
    }

    private func resolveTargetDevice() throws -> SigningContext.TargetDevice? {
        switch platform {
        case .iOS:
            return context.targetDevice
        case .macOS:
            #if os(macOS)
            return try currentMacTargetDevice()
            #else
            return nil
            #endif
        }
    }

    private func waitForDeviceAvailability(udid: String) async throws {
        let normalizedUDID = udid.uppercased()
        let maxAttempts = 30
        var attemptedEnableForDisabledDevice = false

        for attempt in 0 ..< maxAttempts {
            let pages = DeveloperAPIPages {
                try await context.developerAPIClient.devicesGetCollection().ok.body.json
            } next: {
                $0.links.next
            }

            for try await page in pages {
                for device in page.data {
                    guard let deviceUDID = device.attributes?.udid?.uppercased(),
                          deviceUDID == normalizedUDID
                    else {
                        continue
                    }

                    if device.attributes?.status?.value1 == .enabled {
                        return
                    }

                    if device.attributes?.status?.value1 == .disabled,
                       !attemptedEnableForDisabledDevice {
                        attemptedEnableForDisabledDevice = true
                        await tryEnableDevice(device)
                    }
                }
            }

            if attempt < maxAttempts - 1 {
                try await Task.sleep(for: .seconds(1))
            }
        }

        throw Errors.deviceNotAvailable(
            udid: normalizedUDID,
            platform: platform.displayName
        )
    }

    private func tryEnableDevice(_ device: Components.Schemas.Device) async {
        let statusPayload = Components.Schemas.DeviceUpdateRequest.DataPayload.AttributesPayload.StatusPayload(
            value1: .enabled
        )
        let attributes = Components.Schemas.DeviceUpdateRequest.DataPayload.AttributesPayload(
            name: device.attributes?.name,
            status: statusPayload
        )
        let request = Components.Schemas.DeviceUpdateRequest(
            data: .init(
                _type: .devices,
                id: device.id,
                attributes: attributes
            )
        )
        do {
            let response = try await context.developerAPIClient.devicesUpdateInstance(
                path: .init(id: device.id),
                body: .json(request)
            )
            if (try? response.ok) != nil {
                return
            }
        } catch {
            // Best-effort only. We'll continue polling and surface a clearer error if unavailable.
        }
    }

    #if os(macOS)
    private func currentMacTargetDevice() throws -> SigningContext.TargetDevice {
        let udid = try currentMacProvisioningUDID()
        let name = Host.current().localizedName ?? "This Mac"
        return .init(udid: udid, name: name)
    }

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

        // Fallback for environments where system_profiler does not report a provisioning UDID.
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
