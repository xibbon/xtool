import Foundation
import DeveloperAPI

public struct DeveloperServicesAddDeviceOperation: DeveloperServicesOperation {
    public enum Errors: LocalizedError {
        /// `records` describes the device records that Apple returned in the last
        /// check, with only their udid, platform, status, and device class.
        case deviceNotAvailable(udid: String, platform: String, records: [String])

        public var errorDescription: String? {
            switch self {
            case .deviceNotAvailable(let udid, let platform, let records):
                let returned = records.isEmpty ? "no record" : records.joined(separator: "; ")
                return "Device \(udid) is not available for \(platform) provisioning yet. Apple returned: \(returned)."
            }
        }
    }

    /// The number of checks for a device that Apple does not list as enabled yet.
    struct WaitPolicy: Sendable {
        /// Checks after Apple created the device. A new device can take some seconds to appear.
        var newDeviceChecks = 30
        /// Checks after Apple reported that the device exists (HTTP 409), or after an
        /// attempt to enable it. Apple has the device, so a long wait does not help.
        var existingDeviceChecks = 3
        var delay: Duration = .seconds(1)
    }

    /// Tests can set a shorter wait.
    @TaskLocal static var waitPolicy = WaitPolicy()

    public let context: SigningContext
    public let platform: ProvisioningPlatform
    public let useContextTargetDevice: Bool
    private var client: DeveloperAPIClient?

    public init(
        context: SigningContext,
        platform: ProvisioningPlatform = .iOS,
        useContextTargetDevice: Bool = false
    ) {
        self.context = context
        self.platform = platform
        self.useContextTargetDevice = useContextTargetDevice
    }

    /// `client` replaces the client of `context`, for example in tests.
    init(
        context: SigningContext,
        platform: ProvisioningPlatform,
        useContextTargetDevice: Bool,
        client: DeveloperAPIClient?
    ) {
        self.init(context: context, platform: platform, useContextTargetDevice: useContextTargetDevice)
        self.client = client
    }

    private var apiClient: DeveloperAPIClient {
        client ?? context.developerAPIClient
    }

    public func perform() async throws {
        guard let targetDevice = try resolveTargetDevice() else { return }
        let normalizedUDID = targetDevice.udid.uppercased()
        let policy = Self.waitPolicy

        // Device registration is idempotent: if the device is already present and enabled,
        // skip createInstance entirely to avoid unnecessary API conflicts.
        if let existingDevice = try await findRegisteredDevice(udid: normalizedUDID) {
            if existingDevice.attributes?.status?.value1 == .enabled {
                return
            }
            if existingDevice.attributes?.status?.value1 == .disabled {
                await tryEnableDevice(existingDevice)
            }
            try await waitForDeviceAvailability(udid: normalizedUDID, checks: policy.existingDeviceChecks)
            return
        }

        // try to register the device
        let response = try await apiClient.devicesCreateInstance(
            body: .json(.init(data: .init(
                _type: .devices,
                attributes: .init(
                    name: targetDevice.name,
                    platform: .init(platform.bundleIDPlatform),
                    udid: normalizedUDID
                )
            )))
        )

        // we get a 409 CONFLICT if the device was already registered, but the
        // lookup above did not find it. Apple has the device, so check again
        // for a short time only.
        if (try? response.conflict) != nil {
            try await waitForDeviceAvailability(udid: normalizedUDID, checks: policy.existingDeviceChecks)
            return
        }

        // otherwise, we should get a 201 CREATED to indicate that the device
        // was added. any other case is unexpected, and this will throw.
        _ = try response.created
        try await waitForDeviceAvailability(udid: normalizedUDID, checks: policy.newDeviceChecks)
    }

    private func findRegisteredDevice(udid: String) async throws -> Components.Schemas.Device? {
        platform.deviceRecord(withUDID: udid, in: try await devices(withUDID: udid))
    }

    /// The query uses only the UDID. See `ProvisioningPlatform.deviceRecord(withUDID:in:)`.
    private func devices(withUDID udid: String) async throws -> [Components.Schemas.Device] {
        let pages = DeveloperAPIPages {
            try await apiClient.devicesGetCollection(query: .init(
                filter_lbrack_udid_rbrack_: [udid]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        var devices: [Components.Schemas.Device] = []
        for try await page in pages {
            devices += page.data
        }
        return devices
    }

    private func resolveTargetDevice() throws -> SigningContext.TargetDevice? {
        if useContextTargetDevice {
            return context.targetDevice
        }
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

    private func waitForDeviceAvailability(udid: String, checks: Int) async throws {
        let normalizedUDID = udid.uppercased()
        let delay = Self.waitPolicy.delay
        var attemptedEnableForDisabledDevice = false
        var lastRecords: [Components.Schemas.Device] = []

        for check in 0 ..< checks {
            lastRecords = try await devices(withUDID: normalizedUDID)
            if let device = platform.deviceRecord(withUDID: normalizedUDID, in: lastRecords) {
                if device.attributes?.status?.value1 == .enabled {
                    return
                }

                if device.attributes?.status?.value1 == .disabled,
                   !attemptedEnableForDisabledDevice {
                    attemptedEnableForDisabledDevice = true
                    await tryEnableDevice(device)
                }
            }

            if check < checks - 1 {
                try await Task.sleep(for: delay)
            }
        }

        throw Errors.deviceNotAvailable(
            udid: normalizedUDID,
            platform: platform.displayName,
            records: lastRecords.map(\.diagnosticSummary)
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
            let response = try await apiClient.devicesUpdateInstance(
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
        process.arguments = ["SPHardwareDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
        if let document = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
           let hardware = document["SPHardwareDataType"] as? [[String: Any]],
           let udid = hardware.first?["provisioning_UDID"] as? String,
           !udid.isEmpty {
            return udid.uppercased()
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

extension Components.Schemas.Device {
    /// The fields of a device record that diagnostics can show: udid, platform,
    /// status, and device class. The values are Apple's own strings.
    var diagnosticSummary: String {
        let platform = attributes?.platform?.value2 ?? attributes?.platform?.value1?.rawValue ?? "-"
        let status = attributes?.status?.value2 ?? attributes?.status?.value1?.rawValue ?? "-"
        let deviceClass = attributes?.deviceClass?.value2 ?? attributes?.deviceClass?.value1?.rawValue ?? "-"
        return "udid=\(attributes?.udid ?? "-") platform=\(platform) status=\(status) deviceClass=\(deviceClass)"
    }
}
