import Foundation
import Crypto
import X509
import DeveloperAPI
import SignerSupport
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import XKit

private let registerTestSigner: Void = {
    add_signer("CertificateProvisioningTests", { _, _, _, _, _, _, _, _, _, exception in
        exception.initialize(to: strdup("Signing is forbidden in provisioning tests"))
        return 1
    }, { _, _, exception in
        exception.initialize(to: strdup("Executable analysis is forbidden in provisioning tests"))
        return nil
    })
}()

struct CertificateProvisioningTests {
    @Test func exactCertificateIgnoresMatchingSerialWithDifferentDER() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        let resource = fixture.resource(id: "selected")
        var decoy = other.resource(id: "same-serial")
        decoy.attributes?.serialNumber = resource.attributes?.serialNumber
        #expect(try fixture.certificate.resolveResourceID(in: [decoy, resource]) == "selected")
        #expect(throws: (any Error).self) {
            try fixture.certificate.resolveResourceID(in: [decoy])
        }
    }

    @Test func ambiguousInactiveExpiredWrongTypeOrWrongTeamCertificatesFail() throws {
        let fixture = try Fixture()
        #expect(throws: (any Error).self) {
            try fixture.certificate.resolveResourceID(in: [fixture.resource(id: "a"), fixture.resource(id: "b")])
        }
        var inactive = fixture.resource(id: "inactive")
        inactive.attributes?.activated = false
        var expired = fixture.resource(id: "expired")
        expired.attributes?.expirationDate = Date(timeIntervalSince1970: 1)
        var distribution = fixture.resource(id: "distribution")
        distribution.attributes?.certificateType = .init(.distribution)
        for resource in [inactive, expired, distribution] {
            #expect(throws: (any Error).self) {
                try fixture.certificate.resolveResourceID(in: [resource])
            }
        }
        let wrongTeam = ProvisioningCertificate(certificateDER: fixture.certificate.certificateDER, teamID: "OTHER", certificateSHA1: fixture.certificate.certificateSHA1)
        #expect(throws: (any Error).self) {
            try wrongTeam.resolveResourceID(in: [fixture.resource(id: "selected")])
        }
        let wrongDigest = ProvisioningCertificate(certificateDER: fixture.certificate.certificateDER, teamID: "TEAM", certificateSHA1: String(repeating: "0", count: 40))
        #expect(throws: (any Error).self) {
            try wrongDigest.resolveResourceID(in: [fixture.resource(id: "selected")])
        }
    }

    @Test func profileRequestContainsOnlyTheSelectedCertificateAndTargetDevice() throws {
        let request = CertificateProvisioningService.profileRequest(name: "new", bundleResourceID: "app", certificateResourceID: "exact-certificate", deviceResourceID: "exact-device")
        #expect(request.data.relationships.certificates.data.map(\.id) == ["exact-certificate"])
        #expect(request.data.relationships.devices?.data?.map(\.id) == ["exact-device"])
        #expect(request.data.relationships.bundleId.data.id == "app")
    }

    @Test func macProfileRequestUsesMacDevelopmentType() throws {
        let request = CertificateProvisioningService.profileRequest(name: "Mac", bundleResourceID: "app", certificateResourceID: "certificate", deviceResourceID: "mac", platform: .macOS)
        #expect(request.data.attributes.profileType.value1 == .macAppDevelopment)
        #expect(request.data.relationships.devices?.data?.map(\.id) == ["mac"])
        let legacy = CertificateProvisioningService.profileRequest(name: "iOS", bundleResourceID: "app", certificateResourceID: "certificate", deviceResourceID: "phone")
        #expect(legacy.data.attributes.profileType.value1 == .iosAppDevelopment)
    }

    @Test func macNormalizationUsesMacClaimsAndPreservesExactGroups() throws {
        let fixture = try Fixture()
        let requested = try fixture.entitlements([
            "application-identifier": "OLD.com.example.game",
            "get-task-allow": false,
            "com.apple.security.application-groups": ["group.com.example.shared"],
            "keychain-access-groups": ["OLD.com.example.game", "OLD.shared"]
        ])
        let normalized = try CertificateProvisioningPreparation.normalizeEntitlements(requested, isFreeTeam: false, teamID: "TEAM", originalBundleID: "com.example.game", finalBundleID: "com.example.game", context: fixture.context(), platform: .macOS)
        let claims = try CertificateProvisioningPreparation.dictionary(normalized.entitlements)
        #expect(claims["application-identifier"] == nil)
        #expect(claims["get-task-allow"] == nil)
        #expect(claims["com.apple.application-identifier"] as? String == "TEAM.com.example.game")
        #expect(claims["com.apple.security.get-task-allow"] as? Bool == true)
        #expect(claims["com.apple.security.application-groups"] as? [String] == ["group.com.example.shared"])
        #expect(claims["keychain-access-groups"] as? [String] == ["OLD.com.example.game", "OLD.shared"])
    }

    @Test func macHelpersCanHaveIndependentBundleIdentifiers() async throws {
        let fixture = try Fixture()
        let nodes = try [fixture.node(path: ".", id: "com.example.game"),
            fixture.node(path: "Contents/XPCServices/Helper.xpc", id: "org.example.helper")]
        let service = MockService(resources: [fixture.resource(id: "exact")])
        let response = try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(),
            certificate: fixture.certificate, nodes: nodes, platform: .macOS, service: service).perform()
        #expect(response.nodes.count == 2)
        let iosService = MockService(resources: [fixture.resource(id: "exact")])
        await #expect(throws: CertificateProvisioningError.self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(),
                certificate: fixture.certificate, nodes: nodes, service: iosService).perform()
        }
        #expect(await iosService.events.isEmpty)
    }

    @Test func appStoreConnectGroupsFailBeforeAnyAppleWrite() async throws {
        _ = registerTestSigner
        let fixture = try Fixture()
        let context = try SigningContext(auth: .appStoreConnect(.init(id: "fixture", issuerID: "fixture", pem: "not-a-real-key")), targetDevice: .init(udid: "MAC", name: "Fixture"))
        let root = try fixture.node(path: ".", id: "com.example.game")
        let child = CertificateProvisioningNode(relativePath: "Contents/PlugIns/Child.appex", originalBundleID: "com.example.game.child", finalBundleID: "com.example.game.child", requestedEntitlements: try fixture.entitlements(["com.apple.security.application-groups": ["group.com.example.shared"]]))
        let service = MockService(resources: [fixture.resource(id: "exact")])
        await #expect(throws: CertificateProvisioningError.self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: context, certificate: fixture.certificate, nodes: [root, child], platform: .macOS, service: service).perform()
        }
        #expect(await service.events == ["team", "certificates"])
    }

    @Test func repeatedMacProfileRequestsReuseTheSameAuthorizedProfile() async throws {
        let fixture = try Fixture()
        let transport = try ProfileReuseTransport()
        let client = DeveloperAPIClient(serverURL: URL(string: "https://example.invalid")!, configuration: .init(dateTranscoder: .iso8601WithFractionalSeconds), transport: transport)
        let service = CertificateProvisioningService(context: try fixture.context(), platform: .macOS, profileValidator: { data, bundleID in
            data == Data("authorized fixture".utf8) && bundleID == "com.example.game"
        }, client: client)
        for _ in 0..<2 {
            let profile = try await service.createProfile(bundleResourceID: "app", bundleID: "com.example.game", certificateResourceID: "certificate")
            #expect(profile.resourceID == "existing-profile")
        }
        #expect(await transport.operations == ["devices_getCollection", "profiles_getCollection", "devices_getCollection", "profiles_getCollection"])
        #expect(await transport.deviceQueries.allSatisfy { $0.contains("filter%5Budid%5D=TARGET-UDID") && $0.contains("MAC_OS") })
    }

    @Test func expiredOrMismatchedMacProfilesDoNotReuse() async throws {
        let fixture = try Fixture()
        for mismatch in ["expired", "certificate", "device", "type", "bundle", "authorization"] {
            let transport = try ProfileReuseTransport(mismatch: mismatch)
            let client = DeveloperAPIClient(serverURL: URL(string: "https://example.invalid")!, configuration: .init(dateTranscoder: .iso8601WithFractionalSeconds), transport: transport)
            let service = CertificateProvisioningService(context: try fixture.context(), platform: .macOS, profileValidator: { _, _ in
                mismatch != "authorization"
            }, client: client)
            await #expect(throws: (any Error).self) {
                try await service.createProfile(bundleResourceID: "app", bundleID: "com.example.game", certificateResourceID: "certificate")
            }
            #expect(await transport.operations == ["devices_getCollection", "profiles_getCollection", "profiles_createInstance"])
        }
    }

    @Test func serviceErrorsKeepSafeRoleAndDeviceGuidance() {
        struct RawError: Error, CustomStringConvertible {
            let description: String
        }
        let typed = ClientError(operationID: "profiles_createInstance", operationInput: "secret input", response: HTTPResponse(status: .forbidden), causeDescription: "secret response", underlyingError: RawError(description: "opaque"))
        let typedGuidance = DeveloperServicesCertificateProvisioningOperation.safeError(typed).localizedDescription
        #expect(typedGuidance.contains("Admin or App Manager"))
        #expect(!typedGuidance.contains("secret"))
        let forbidden = DeveloperServicesCertificateProvisioningOperation.safeError(RawError(description: "403 forbidden secret token and response"))
        #expect(forbidden.localizedDescription.contains("Admin or App Manager"))
        #expect(!forbidden.localizedDescription.contains("secret"))
        let devices = DeveloperServicesCertificateProvisioningOperation.safeError(RawError(description: "No current macOS devices secret response"))
        #expect(devices.localizedDescription.contains("macOS"))
        #expect(!devices.localizedDescription.contains("secret"))
    }

    @Test func createsReplacementWithoutDeletingExistingProfilesAndPreparesWholeGraphFirst() async throws {
        let fixture = try Fixture()
        let context = try fixture.context()
        let nodes = try [fixture.node(path: ".", id: "com.example.game"), fixture.node(path: "PlugIns/Child.appex", id: "com.example.game.child")]
        let service = MockService(resources: [fixture.resource(id: "exact")])
        let result = try await DeveloperServicesCertificateProvisioningOperation(context: context, certificate: fixture.certificate, nodes: nodes, service: service).perform()
        #expect(result.certificateResourceID == "exact")
        #expect(result.nodes.count == 2)
        #expect(result.nodes.allSatisfy { $0.profileResourceID.hasPrefix("replacement-") })
        #expect(await service.existingProfile == Data("original profile".utf8))
        #expect(await service.events == ["team", "certificates", "register", "prepare:.", "prepare:PlugIns/Child.appex", "create:com.example.game:exact", "create:com.example.game.child:exact"])
    }

    @Test func profileLimitDoesNotDeleteOldProfileOrTryAnotherCertificate() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], failWithLimit: true)
        do {
            _ = try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
            Issue.record("Expected an explicit profile-limit decision")
        } catch CertificateProvisioningError.profileLimitRequiresDecision(let bundleID) {
            #expect(bundleID == "com.example.game")
        }
        #expect(await service.existingProfile == Data("original profile".utf8))
        #expect(await service.events.filter { $0.hasPrefix("create:") }.count == 1)
    }

    @Test func noMatchingCertificateFailsBeforeDeviceOrAppMutation() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [])
        await #expect(throws: (any Error).self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        }
        #expect(await service.events == ["team", "certificates"])
    }

    @Test func cancellationDoesNotCreateAProfile() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], cancelDuringPrepare: true)
        await #expect(throws: CancellationError.self) {
            try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        }
        #expect(await service.events.allSatisfy { !$0.hasPrefix("create:") })
        #expect(await service.existingProfile == Data("original profile".utf8))
    }

    @Test func devicePropagationRetriesTheSameCertificateWithoutReplacingEarlierProfiles() async throws {
        let fixture = try Fixture()
        let service = MockService(resources: [fixture.resource(id: "exact")], transientProfileFailures: 1)
        let response = try await DeveloperServicesCertificateProvisioningOperation(context: fixture.context(), certificate: fixture.certificate, nodes: [fixture.node(path: ".", id: "com.example.game")], service: service).perform()
        #expect(response.nodes.count == 1)
        #expect(await service.events.filter { $0.hasPrefix("create:") } == ["create:com.example.game:exact", "create:com.example.game:exact"])
        #expect(await service.events.filter { $0 == "register" }.count == 2)
        #expect(await service.existingProfile == Data("original profile".utf8))
    }

    @Test func mappingAndFreeTeamFilteringAreExplicitAndPaidUnknownClaimsSurvive() throws {
        let fixture = try Fixture()
        let context = try fixture.context()
        let requested = try fixture.entitlements([
            "com.example.unknown": true,
            "com.apple.security.application-groups": ["group.com.example.z", "group.com.example.a"],
            "application-identifier": "OLD.com.example.game",
            "keychain-access-groups": ["OLD.com.example.game", "OLD.shared"]
        ])
        let final = CertificateProvisioningPreparation.mapBundleID(original: "com.example.game", context: context)
        #expect(final == "XTL-TEAM.com.example.game")
        #expect(CertificateProvisioningPreparation.mapBundleID(original: final, context: context) == final)
        let paid = try CertificateProvisioningPreparation.normalizeEntitlements(requested, isFreeTeam: false, teamID: "TEAM", originalBundleID: "com.example.game", finalBundleID: final, context: context)
        let paidDictionary = try CertificateProvisioningPreparation.dictionary(paid.entitlements)
        #expect(paidDictionary["com.example.unknown"] as? Bool == true)
        #expect(paidDictionary["keychain-access-groups"] as? [String] == ["TEAM.\(final)", "TEAM.shared"])
        #expect(paidDictionary["com.apple.security.application-groups"] as? [String] == ["group.XTL-TEAM.com.example.z", "group.XTL-TEAM.com.example.a"])
        #expect(paid.removedEntitlementKeys.isEmpty)
        let free = try CertificateProvisioningPreparation.normalizeEntitlements(requested, isFreeTeam: true, teamID: "TEAM", originalBundleID: "com.example.game", finalBundleID: final, context: context)
        #expect(Set(free.removedEntitlementKeys) == ["com.example.unknown", "com.apple.security.application-groups"])
    }

    @Test func observerCountsActualMiddlewareInvocationsAndRestoresScope() async throws {
        let count = Counter()
        let middleware = DeveloperServicesAPIObservationMiddleware()
        let request = HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/v1/certificates")
        try await ProvisioningAPICallObserver.$observer.withValue({ _ in count.increment() }) {
            for _ in 0..<3 {
                _ = try await middleware.intercept(request, body: nil, baseURL: URL(string: "https://example.invalid")!, operationID: "certificatesGetCollection") { _, _, _ in
                    (HTTPResponse(status: .ok), nil)
                }
            }
        }
        #expect(count.value == 3)
        ProvisioningAPICallObserver.observer("outside-scope")
        #expect(count.value == 3)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }
    func increment() {
        lock.withLock { count += 1 }
    }
}

private struct Fixture {
    let certificate: ProvisioningCertificate

    init() throws {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            OrganizationalUnitName("TEAM")
            CommonName("Apple Development: Test")
        }
        let certificate = try X509.Certificate(
            version: .v3,
            serialNumber: .init(bytes: [1]),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-3600),
            notValidAfter: Date().addingTimeInterval(86400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: .init {},
            issuerPrivateKey: .init(key)
        )
        let data = try XKit.Certificate(raw: certificate).data()
        self.certificate = ProvisioningCertificate(certificateDER: data, teamID: "TEAM", certificateSHA1: ProvisioningCertificate.sha1(data))
    }

    func resource(id: String) -> DeveloperServicesCertificate {
        .init(_type: .certificates, id: id, attributes: .init(
            certificateType: .init(.development),
            serialNumber: "01",
            expirationDate: Date().addingTimeInterval(86400),
            certificateContent: certificate.certificateDER.base64EncodedString(),
            activated: true
        ))
    }

    func context() throws -> SigningContext {
        _ = registerTestSigner
        return try SigningContext(auth: .xcode(.init(
            loginToken: .init(adsid: "test", token: "not-a-real-token", expiry: .distantFuture),
            teamID: .init(rawValue: "TEAM")
        )), targetDevice: .init(udid: "TARGET-UDID", name: "Fixture"))
    }

    func node(path: String, id: String) throws -> CertificateProvisioningNode {
        .init(relativePath: path, originalBundleID: id, finalBundleID: id, requestedEntitlements: try Entitlements(entitlements: []))
    }

    func entitlements(_ dictionary: [String: Any]) throws -> Entitlements {
        try PropertyListDecoder().decode(Entitlements.self, from: PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0))
    }
}

private actor MockService: CertificateProvisioningServing {
    let resources: [DeveloperServicesCertificate]
    let failWithLimit: Bool
    let cancelDuringPrepare: Bool
    var transientProfileFailures: Int
    let existingProfile = Data("original profile".utf8)
    var events: [String] = []

    init(resources: [DeveloperServicesCertificate], failWithLimit: Bool = false, cancelDuringPrepare: Bool = false, transientProfileFailures: Int = 0) {
        self.resources = resources
        self.failWithLimit = failWithLimit
        self.cancelDuringPrepare = cancelDuringPrepare
        self.transientProfileFailures = transientProfileFailures
    }

    func team() -> (teamID: String?, isFree: Bool) {
        events.append("team")
        return ("TEAM", false)
    }

    func certificates() -> [DeveloperServicesCertificate] {
        events.append("certificates")
        return resources
    }

    func registerDevice() {
        events.append("register")
    }

    func prepareApp(_ node: CertificateProvisioningNode) throws -> String {
        events.append("prepare:" + node.relativePath)
        if cancelDuringPrepare {
            throw CancellationError()
        }
        return node.finalBundleID
    }

    func createProfile(bundleResourceID: String, bundleID: String, certificateResourceID: String) throws -> CertificateProvisioningProfile {
        events.append("create:\(bundleID):\(certificateResourceID)")
        if transientProfileFailures > 0 {
            transientProfileFailures -= 1
            throw DeveloperServicesFetchProfileOperation.Errors.noRegisteredDevices("iOS")
        }
        if failWithLimit {
            throw CertificateProvisioningError.profileLimitRequiresDecision(bundleID: bundleID)
        }
        return .init(resourceID: "replacement-" + bundleID, name: "Xogot replacement", data: Data("replacement profile".utf8))
    }
}

private actor ProfileReuseTransport: ClientTransport {
    let profileBody: Data
    var operations: [String] = []
    var deviceQueries: [String] = []

    init(mismatch: String = "") throws {
        let profile: [String: Any] = [
            "type": "profiles",
            "id": "existing-profile",
            "attributes": [
                "name": "Existing Mac profile",
                "profileType": mismatch == "type" ? "IOS_APP_DEVELOPMENT" : "MAC_APP_DEVELOPMENT",
                "profileState": "ACTIVE",
                "expirationDate": mismatch == "expired" ? "2000-01-01T00:00:00.000Z" : "2099-01-01T00:00:00.000Z",
                "profileContent": Data("authorized fixture".utf8).base64EncodedString()
            ],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": mismatch == "bundle" ? "other-app" : "app"]],
                "certificates": ["data": [["type": "certificates", "id": mismatch == "certificate" ? "other-certificate" : "certificate"]]],
                "devices": ["data": [["type": "devices", "id": mismatch == "device" ? "other-device" : "mac"]]]
            ]
        ]
        self.profileBody = try JSONSerialization.data(withJSONObject: ["data": [profile], "links": ["self": "https://example.invalid/v1/profiles"]])
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        operations.append(operationID)
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        switch operationID {
        case "devices_getCollection":
            deviceQueries.append(request.path ?? "")
            let device: [String: Any] = ["type": "devices", "id": "mac", "attributes": ["platform": "MAC_OS", "udid": "TARGET-UDID", "status": "ENABLED"]]
            let data = try JSONSerialization.data(withJSONObject: ["data": [device], "links": ["self": "https://example.invalid/v1/devices"]])
            return (response, HTTPBody(data))
        case "profiles_getCollection":
            return (response, HTTPBody(profileBody))
        case "profiles_createInstance":
            struct CreationReached: Error {}
            throw CreationReached()
        default:
            Issue.record("Unexpected provisioning API call: \(operationID)")
            struct UnexpectedRequest: Error {}
            throw UnexpectedRequest()
        }
    }
}
