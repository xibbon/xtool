import Foundation
import DeveloperAPI
import OpenAPIRuntime

public struct CertificateProvisioningProfile: Sendable {
    public let resourceID: String
    public let name: String
    public let data: Data

    public init(resourceID: String, name: String, data: Data) {
        self.resourceID = resourceID
        self.name = name
        self.data = data
    }
}

public struct CertificateProvisioningResult: Sendable {
    public let node: CertificateProvisioningNode
    public let profileResourceID: String
    public let profileName: String
    public let profileData: Data
    public let entitlements: Entitlements
    public let removedEntitlementKeys: [String]
}

public struct CertificateProvisioningResponse: Sendable {
    public let isFreeTeam: Bool
    public let certificateResourceID: String
    public let nodes: [CertificateProvisioningResult]
}

/// Injectable boundary for tests. There is deliberately no delete-profile,
/// create-certificate, revoke-certificate, or private-key operation here.
public protocol CertificateProvisioningServing: Sendable {
    func team() async throws -> (teamID: String?, isFree: Bool)
    func certificates() async throws -> [DeveloperServicesCertificate]
    func registerDevice() async throws
    func prepareApp(_ node: CertificateProvisioningNode) async throws -> String
    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) async throws -> CertificateProvisioningProfile
}

/// Cold provisioning with a caller-selected public certificate and explicit graph.
/// The caller validates the returned CMS, profile authorization, and shared state
/// before saving a snapshot. This operation never deletes an existing profile.
public struct DeveloperServicesCertificateProvisioningOperation: Sendable {
    public let context: SigningContext
    public let certificate: ProvisioningCertificate
    public let nodes: [CertificateProvisioningNode]
    public let platform: ProvisioningPlatform
    private let service: any CertificateProvisioningServing
    private let apiCallObserver: @Sendable (String) -> Void
    private let status: @Sendable (String) -> Void

    public init(
        context: SigningContext,
        certificate: ProvisioningCertificate,
        nodes: [CertificateProvisioningNode],
        platform: ProvisioningPlatform = .iOS,
        profileValidator: (@Sendable (Data, String) -> Bool)? = nil,
        apiCallObserver: @escaping @Sendable (String) -> Void = { _ in },
        status: @escaping @Sendable (String) -> Void = { _ in },
        service: (any CertificateProvisioningServing)? = nil
    ) {
        self.context = context
        self.certificate = certificate
        self.nodes = nodes
        self.platform = platform
        self.apiCallObserver = apiCallObserver
        self.status = status
        self.service = service ?? CertificateProvisioningService(context: context, platform: platform, profileValidator: profileValidator)
    }

    /// Read-only resource discovery for deterministic local-identity selection.
    /// This inherits ProvisioningAPICallObserver's task-local scope.
    public static func availableCertificates(context: SigningContext) async throws -> [DeveloperServicesCertificate] {
        do {
            return try await ProvisioningAPICallObserver.$suppressResponseBodies.withValue(true) {
                try await CertificateProvisioningService(context: context, platform: .iOS).certificates()
            }
        } catch {
            throw Self.safeError(error)
        }
    }

    public func perform() async throws -> CertificateProvisioningResponse {
        do {
            return try await ProvisioningAPICallObserver.$suppressResponseBodies.withValue(true) {
                try await ProvisioningAPICallObserver.$observer.withValue(apiCallObserver) {
                    try await provision()
                }
            }
        } catch {
            throw Self.safeError(error)
        }
    }

    static func safeError(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled {
            return CancellationError()
        }
        if error is CertificateProvisioningError || error is DeveloperServicesFetchProfileOperation.Errors || error is DeveloperServicesAddDeviceOperation.Errors {
            return error
        }
        // The anisette server failed before the request went to Apple. Its status and
        // text are not Apple's, so the 403 and device mappings below do not apply.
        if error is OmnisetteError || (error as? ClientError)?.underlyingError is OmnisetteError {
            return CertificateProvisioningError.requestFailed(detail: safeDetail(error))
        }
        if let clientError = error as? ClientError, clientError.response?.status.code == 403 {
            return CertificateProvisioningError.insufficientPermissions
        }
        let message = String(describing: error).lowercased()
        if message.contains("403") || message.contains("forbidden") {
            return CertificateProvisioningError.insufficientPermissions
        }
        if message.contains("no current") && message.contains("devices") {
            return DeveloperServicesFetchProfileOperation.Errors.noRegisteredDevices(message.contains("mac") ? "macOS" : "iOS")
        }
        // OpenAPI ClientError can include authentication headers and raw bodies.
        // Keep these diagnostic objects inside the provisioning boundary. Report only
        // the safe detail: the operation, the HTTP status, and the failure text.
        return CertificateProvisioningError.requestFailed(detail: safeDetail(error))
    }

    /// Builds a description from safe facts only. It never uses `String(describing:)`
    /// of a ClientError, its request, request body, header fields, response body,
    /// or operation input.
    static func safeDetail(_ error: any Error) -> String {
        guard let clientError = error as? ClientError else {
            return safeSummary(error)
        }
        var operation = clientError.operationID
        if let status = clientError.response?.status.code {
            operation += ", HTTP \(status)"
        }
        return "\(operation): \(clientError.causeDescription) \(safeSummary(clientError.underlyingError))"
    }

    /// The type name and the localized description of an error.
    private static func safeSummary(_ error: any Error) -> String {
        let qualifiedName = String(reflecting: type(of: error))
        var typeName = qualifiedName.split(separator: ".", maxSplits: 1).last.map(String.init) ?? qualifiedName
        // Bridged errors, such as URLError, have the type NSError. Their domain and
        // code identify them better.
        if type(of: error) is NSError.Type {
            let nsError = error as NSError
            typeName = "\(nsError.domain) \(nsError.code)"
        }
        // An OpenAPIRuntime error describes the whole response, with its header fields.
        // Keep only Apple's error objects or the HTTP status from it.
        if qualifiedName.hasPrefix("OpenAPIRuntime.") {
            let appleErrors = appleErrors(in: error)
            if !appleErrors.isEmpty {
                return "\(typeName): Apple returned \(appleErrors.map(describe).joined(separator: "; "))"
            }
            guard let status = undocumentedStatus(in: String(describing: error)) else {
                return typeName
            }
            return "\(typeName): unexpected HTTP status \(status)"
        }
        return "\(typeName): \(error.localizedDescription)"
    }

    /// Finds Apple's error objects in a reply that the `ok` accessor rejected, for
    /// example a decoded HTTP 400 reply. The reply is an internal value of the
    /// OpenAPIRuntime error, so a Mirror finds it.
    static func appleErrors(in value: Any, depth: Int = 0) -> [Components.Schemas.ErrorResponse.ErrorsPayloadPayload] {
        if let response = value as? Components.Schemas.ErrorResponse {
            return response.errors ?? []
        }
        guard depth < 8 else {
            return []
        }
        for child in Mirror(reflecting: value).children {
            let errors = appleErrors(in: child.value, depth: depth + 1)
            if !errors.isEmpty {
                return errors
            }
        }
        return []
    }

    /// Uses only status, code, title, detail, and the name of the rejected parameter.
    private static func describe(_ error: Components.Schemas.ErrorResponse.ErrorsPayloadPayload) -> String {
        var text = "HTTP \(error.status) \(error.code): \(error.title). \(error.detail)"
        if case .ErrorSourceParameter(let source) = error.source {
            text += " (parameter \(source.parameter))"
        }
        return text
    }

    /// Finds the status of an undocumented response, for example
    /// `undocumented(statusCode: 401, ...)`.
    private static func undocumentedStatus(in description: String) -> Int? {
        guard let range = description.range(of: "statusCode: ") else {
            return nil
        }
        let digits = description[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func provision() async throws -> CertificateProvisioningResponse {
        try Task.checkCancellation()
        try certificate.validate(now: Date())
        guard let device = context.targetDevice, !device.udid.isEmpty,
              !nodes.isEmpty,
              Set(nodes.map(\.relativePath)).count == nodes.count,
              Set(nodes.map(\.finalBundleID)).count == nodes.count else {
            throw CertificateProvisioningError.invalidRequest("Specify one device and unique bundle paths and identifiers.")
        }
        for node in nodes {
            guard !node.originalBundleID.isEmpty,
                  !node.finalBundleID.isEmpty,
                  !node.finalBundleID.contains("*"),
                  node.relativePath == "." || (!node.relativePath.isEmpty && !node.relativePath.hasPrefix("/") && !node.relativePath.split(separator: "/").contains("..")) else {
                throw CertificateProvisioningError.invalidRequest("A bundle path or identifier is invalid.")
            }
            let parent = nodes.filter {
                $0.relativePath != node.relativePath &&
                    ($0.relativePath == "." || node.relativePath.hasPrefix($0.relativePath + "/"))
            }.max { $0.relativePath.count < $1.relativePath.count }
            if platform == .iOS, let parent, !node.finalBundleID.hasPrefix(parent.finalBundleID + ".") {
                throw CertificateProvisioningError.invalidRequest("A child identifier does not extend its parent identifier.")
            }
        }
        let team = try await service.team()
        if let teamID = team.teamID, teamID != certificate.teamID {
            throw CertificateProvisioningError.invalidRequest("The authenticated team differs from the certificate team.")
        }
        let certificateID = try certificate.resolveResourceID(in: await service.certificates())
        var prepared: [(CertificateProvisioningNode, [String])] = []
        for node in nodes.sorted(by: { $0.relativePath < $1.relativePath }) {
            let normalized = try CertificateProvisioningPreparation.normalizeEntitlements(
                node.requestedEntitlements,
                isFreeTeam: team.isFree,
                teamID: certificate.teamID,
                originalBundleID: node.originalBundleID,
                finalBundleID: node.finalBundleID,
                context: context,
                platform: platform
            )
            prepared.append((CertificateProvisioningNode(
                relativePath: node.relativePath,
                originalBundleID: node.originalBundleID,
                finalBundleID: node.finalBundleID,
                requestedEntitlements: normalized.entitlements
            ), normalized.removedEntitlementKeys))
        }
        if case .appStoreConnect = context.auth {
            for (node, _) in prepared {
                if let groups = try node.requestedEntitlements.entitlements().first(where: { $0 is AppGroupEntitlement }) as? AppGroupEntitlement,
                   !groups.rawValue.isEmpty {
                    throw CertificateProvisioningError.unsupportedAppGroupAuthentication
                }
            }
        }
        status("Registering the target device for certificate-only provisioning.")
        do {
            try await service.registerDevice()
        } catch {
            try Task.checkCancellation()
            guard Self.registrationCanPropagate(error) else {
                throw error
            }
            status("Device registration is pending. Profile creation will retry.")
        }
        // Prepare the whole supplied graph first. Shared capabilities must be
        // settled before any replacement profile is created.
        var applications: [(CertificateProvisioningNode, [String], String)] = []
        for (node, removed) in prepared {
            try Task.checkCancellation()
            let resourceID = try await service.prepareApp(node)
            applications.append((node, removed, resourceID))
        }
        var result: [CertificateProvisioningResult] = []
        for (node, removed, applicationID) in applications {
            try Task.checkCancellation()
            let profile = try await createProfileWithRetry(node: node, applicationID: applicationID, certificateID: certificateID)
            result.append(CertificateProvisioningResult(
                node: node,
                profileResourceID: profile.resourceID,
                profileName: profile.name,
                profileData: profile.data,
                entitlements: node.requestedEntitlements,
                removedEntitlementKeys: removed
            ))
        }
        return CertificateProvisioningResponse(isFreeTeam: team.isFree, certificateResourceID: certificateID, nodes: result)
    }

    private func createProfileWithRetry(node: CertificateProvisioningNode, applicationID: String, certificateID: String) async throws -> CertificateProvisioningProfile {
        for attempt in 1...4 {
            try Task.checkCancellation()
            do {
                return try await service.createProfile(bundleResourceID: applicationID, bundleID: node.finalBundleID, certificateResourceID: certificateID)
            } catch {
                try Task.checkCancellation()
                guard attempt < 4, Self.shouldRetryProfile(error) else {
                    throw error
                }
                status("Waiting for device and App ID registration to propagate (attempt \(attempt + 1)/4).")
                do {
                    try await service.registerDevice()
                } catch {
                    try Task.checkCancellation()
                    if !Self.registrationCanPropagate(error) {
                        throw error
                    }
                }
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        throw CertificateProvisioningError.invalidProfileResponse
    }

    private static func shouldRetryProfile(_ error: any Error) -> Bool {
        if let error = error as? DeveloperServicesFetchProfileOperation.Errors {
            switch error {
            case .noRegisteredDevices, .bundleIDNotFound:
                return true
            default:
                return false
            }
        }
        let message = String(describing: error).lowercased()
        return message.contains("no current") && message.contains("devices")
    }

    private static func registrationCanPropagate(_ error: any Error) -> Bool {
        if let clientError = error as? ClientError, clientError.response?.status.code == 403 {
            return false
        }
        let diagnostic = String(describing: error).lowercased()
        if diagnostic.contains("403") || diagnostic.contains("forbidden") {
            return false
        }
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
}

struct CertificateProvisioningService: CertificateProvisioningServing {
    let context: SigningContext
    let platform: ProvisioningPlatform
    var profileValidator: (@Sendable (Data, String) -> Bool)? = nil
    var client: DeveloperAPIClient? = nil

    private var apiClient: DeveloperAPIClient {
        client ?? context.developerAPIClient
    }

    func team() async throws -> (teamID: String?, isFree: Bool) {
        let team = try await context.auth.team()
        if case .xcode(let auth) = context.auth {
            guard team?.id == auth.teamID, team?.status.lowercased() == "active" else {
                throw CertificateProvisioningError.invalidRequest("The authenticated team is unavailable.")
            }
        }
        return (team?.id.rawValue, team?.isFree == true)
    }

    func certificates() async throws -> [DeveloperServicesCertificate] {
        // With an Xcode login, Apple rejects fields[certificates]: "A parameter
        // 'fields[certificates]' has an invalid value : ''activated' does not exist.'"
        // (PARAMETER_ERROR.INVALID). Without fields, both an Xcode login and an App
        // Store Connect key return certificateContent and expirationDate.
        let pages = DeveloperAPIPages {
            try await apiClient.certificatesGetCollection(query: .init(
                filter_lbrack_certificateType_rbrack_: [.development, .iosDevelopment]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        var result: [DeveloperServicesCertificate] = []
        for try await page in pages {
            result += page.data
        }
        try Task.checkCancellation()
        return result
    }

    func registerDevice() async throws {
        try await DeveloperServicesAddDeviceOperation(context: context, platform: platform, useContextTargetDevice: true, client: client).perform()
    }

    func prepareApp(_ node: CertificateProvisioningNode) async throws -> String {
        let groups = try node.requestedEntitlements.entitlements().first(where: { $0 is AppGroupEntitlement }) as? AppGroupEntitlement
        if let groups, !groups.rawValue.isEmpty, case .appStoreConnect = context.auth {
            throw CertificateProvisioningError.unsupportedAppGroupAuthentication
        }
        let app = try await DeveloperServicesUpsertAppOperation(
            context: context,
            originalBundleID: node.originalBundleID,
            newBundleID: node.finalBundleID,
            entitlements: node.requestedEntitlements,
            platform: platform
        ).perform()
        if let groups, !groups.rawValue.isEmpty {
            guard let operation = DeveloperServicesAssignAppGroupsOperation(
                context: context,
                groupIDs: groups.rawValue,
                appID: app,
                platform: platform,
                preserveExactGroupIDs: true
            ) else {
                throw CertificateProvisioningError.unsupportedAppGroupAuthentication
            }
            let assigned = try await operation.perform()
            guard Set(assigned) == Set(groups.rawValue) else {
                throw CertificateProvisioningError.invalidRequest("The assigned shared groups differ from the requested groups.")
            }
        }
        return app.id
    }

    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) async throws -> CertificateProvisioningProfile {
        guard let deviceUDID = context.targetDevice?.udid.uppercased() else {
            throw CertificateProvisioningError.invalidRequest("The target device is missing.")
        }
        // The UDID selects the device. Apple's records do not always use the spec's
        // platform values, see ProvisioningPlatform.deviceRecord(withUDID:in:).
        let pages = DeveloperAPIPages {
            try await apiClient.devicesGetCollection(query: .init(
                filter_lbrack_udid_rbrack_: [deviceUDID],
                filter_lbrack_status_rbrack_: [.enabled]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        var devices: [Components.Schemas.Device] = []
        for try await page in pages {
            devices += page.data.filter {
                $0.attributes?.status?.value1 == .enabled
            }
        }
        try Task.checkCancellation()
        guard let device = platform.deviceRecord(withUDID: deviceUDID, in: devices) else {
            throw DeveloperServicesFetchProfileOperation.Errors.noRegisteredDevices(platform.displayName)
        }
        if let existing = try await reusableProfile(bundleResourceID: bundleResourceID, bundleID: bundleID, certificateResourceID: certificateResourceID, device: device) {
            return existing
        }
        let name = "Xogot development \(bundleID) \(UUID().uuidString)"
        let response = try await apiClient.profilesCreateInstance(body: .json(Self.profileRequest(
            name: name,
            bundleResourceID: bundleResourceID,
            certificateResourceID: certificateResourceID,
            deviceResourceID: device.id,
            platform: platform
        )))
        let profile: Components.Schemas.Profile
        do {
            profile = try response.created.body.json.data
        } catch {
            let message = String(describing: response).lowercased()
            if message.contains("limit") || message.contains("maximum") || message.contains("too many") {
                throw CertificateProvisioningError.profileLimitRequiresDecision(bundleID: bundleID)
            }
            if message.contains("notfound") || message.contains("not found") {
                throw DeveloperServicesFetchProfileOperation.Errors.bundleIDNotFound(bundleID)
            }
            throw error
        }
        guard !profile.id.isEmpty,
              let returnedName = profile.attributes?.name, returnedName == name,
              profile.attributes?.profileState?.value1 == .active,
              let content = profile.attributes?.profileContent,
              let data = Data(base64Encoded: content), !data.isEmpty else {
            throw CertificateProvisioningError.invalidProfileResponse
        }
        // Check that Apple returned a parseable container. Full CMS trust and
        // entitlement authorization are the caller's validation boundary.
        _ = try Mobileprovision(data: data)
        return CertificateProvisioningProfile(resourceID: profile.id, name: returnedName, data: data)
    }

    private func reusableProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String, device: Components.Schemas.Device) async throws -> CertificateProvisioningProfile? {
        guard let profileValidator else {
            return nil
        }
        let pages = DeveloperAPIPages {
            try await apiClient.profilesGetCollection(query: .init(
                filter_lbrack_profileType_rbrack_: [platform == .macOS ? .macAppDevelopment : .iosAppDevelopment],
                filter_lbrack_profileState_rbrack_: [.active],
                include: [.bundleId, .devices, .certificates]
            )).ok.body.json
        } next: {
            $0.links.next
        }
        for try await page in pages {
            for profile in page.data {
                guard profile.attributes?.profileState?.value1 == .active,
                      profile.attributes?.profileType?.value1?.rawValue == platform.profileType.rawValue,
                      let expiration = profile.attributes?.expirationDate, expiration > Date(),
                      profile.relationships?.bundleId?.data?.id == bundleResourceID,
                      profile.relationships?.certificates?.data?.map(\.id) == [certificateResourceID],
                      profile.relationships?.devices?.data?.contains(where: { $0.id == device.id }) == true,
                      let name = profile.attributes?.name,
                      let content = profile.attributes?.profileContent,
                      let data = Data(base64Encoded: content),
                      profileValidator(data, bundleID) else {
                    continue
                }
                return CertificateProvisioningProfile(resourceID: profile.id, name: name, data: data)
            }
        }
        return nil
    }

    static func profileRequest(name: String, bundleResourceID: String, certificateResourceID: String, deviceResourceID: String, platform: ProvisioningPlatform = .iOS) -> Components.Schemas.ProfileCreateRequest {
        .init(data: .init(
            _type: .profiles,
            attributes: .init(name: name, profileType: .init(platform.profileType)),
            relationships: .init(
                bundleId: .init(data: .init(_type: .bundleIds, id: bundleResourceID)),
                devices: .init(data: [.init(_type: .devices, id: deviceResourceID)]),
                certificates: .init(data: [.init(_type: .certificates, id: certificateResourceID)])
            )
        ))
    }
}
