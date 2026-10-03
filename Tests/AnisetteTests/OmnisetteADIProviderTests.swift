import Foundation
import Dependencies
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import XKit

private let server = URL(string: "https://anisette.example")!

// Values of a successful reply. The error messages must never contain them.
private let machineID = "TUFDSElORS1JRC1TRUNSRVQ="
private let oneTimePassword = "T05FLVRJTUUtU0VDUkVU"

/// Gives one fixed reply to each anisette request, and counts the requests.
private final class FakeAnisetteServer: HTTPClientProtocol, ClientTransport, @unchecked Sendable {
    private let status: Int
    private let contentType: String?
    private let body: String
    private let lock = NSLock()
    private var paths: [String] = []

    init(status: Int, contentType: String?, body: String) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    var requestPaths: [String] {
        lock.withLock { paths }
    }

    var asOpenAPITransport: ClientTransport { self }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock {
            paths.append(request.path ?? "")
        }
        var response = HTTPResponse(status: .init(code: status))
        if let contentType {
            response.headerFields[.contentType] = contentType
        }
        return (response, HTTPBody(self.body))
    }

    func makeWebSocket(url: URL) async throws -> any WebSocketSession {
        Issue.record("The tests use stored provisioning data and never open a WebSocket")
        throw CancellationError()
    }
}

/// Runs `operation` with stored ADI provisioning data and the anisette server `fake`.
private func withAnisetteServer<T>(
    _ fake: FakeAnisetteServer,
    operation: () async throws -> T
) async throws -> T {
    let storage = MemoryKeyValueStorage()
    try storage.setString(UUID().uuidString, forKey: "XTLLocalUserUID")
    try storage.setData(Data("stored ADI state".utf8), forKey: "XTLProvisioningInfo")
    try storage.setString("17106176", forKey: "XTLRoutingInfo")
    return try await withDependencies {
        $0.httpClient = fake
        $0.keyValueStorage = storage
        $0.rawADIProvider = OmnisetteADIProvider(url: server)
        $0.deviceInfoProvider = DeviceInfoProvider {
            DeviceInfo(
                deviceID: "DEVICE-ID",
                romAddress: "ROM",
                mlbSerialNumber: "MLB",
                serialNumber: "SERIAL",
                modelID: "Mac14,2"
            )
        }
    } operation: {
        try await withDependencies {
            $0.anisetteDataProvider = ADIDataProvider()
        } operation: {
            try await operation()
        }
    }
}

/// Sends one Developer API request through the Xcode authentication middleware.
/// Returns the number of requests that went to Apple.
private func sendThroughMiddleware() async throws -> Int {
    let middleware = DeveloperAPIXcodeAuthMiddleware(authData: XcodeAuthData(
        loginToken: DeveloperServicesLoginToken(adsid: "ADSID", token: "GS-TOKEN", expiry: .distantFuture),
        teamID: DeveloperServicesTeam.ID(rawValue: "TEAM")
    ))
    let appleRequests = LockedCounter()
    _ = try await middleware.intercept(
        HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/v1/certificates"),
        body: nil,
        baseURL: URL(string: "https://example.invalid")!,
        operationID: "certificates_getCollection"
    ) { _, _, _ in
        appleRequests.increment()
        return (HTTPResponse(status: .ok), nil)
    }
    return appleRequests.value
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}

private func expectNoReplyValues(_ message: String) {
    #expect(!message.contains(machineID))
    #expect(!message.contains(oneTimePassword))
}

struct OmnisetteADIProviderTests {
    @Test func validHeadersReturnAnisetteData() async throws {
        let fake = FakeAnisetteServer(status: 200, contentType: "application/json", body: """
            {"result":"Headers","X-Apple-I-MD":"\(oneTimePassword)","X-Apple-I-MD-M":"\(machineID)","X-Apple-I-MD-RINFO":"17106176"}
            """)
        let data = try await withAnisetteServer(fake) {
            try await ADIDataProvider().fetchAnisetteData()
        }
        #expect(data.oneTimePassword == oneTimePassword)
        #expect(data.machineID == machineID)
        #expect(data.routingInfo == 17106176)
        #expect(fake.requestPaths == ["/v3/get_headers"])

        let appleRequests = try await withAnisetteServer(fake) {
            try await sendThroughMiddleware()
        }
        #expect(appleRequests == 1)
    }

    @Test func serverFailureNamesServerAndStatusAndIsRetried() async throws {
        let fake = FakeAnisetteServer(status: 502, contentType: "text/html", body: "<html>502 Bad Gateway</html>")
        do {
            _ = try await withAnisetteServer(fake) {
                try await sendThroughMiddleware()
            }
            Issue.record("Expected an anisette server error")
        } catch let error as OmnisetteError {
            let message = error.localizedDescription
            #expect(message.contains(server.absoluteString))
            #expect(message.contains("502"))
            #expect(!message.contains("Bad Gateway"))
        }
        #expect(fake.requestPaths.count == 3)
    }

    @Test func emptyReplyIsNotAnisetteDataAndIsRetried() async throws {
        let fake = FakeAnisetteServer(status: 200, contentType: nil, body: "")
        do {
            _ = try await withAnisetteServer(fake) {
                try await sendThroughMiddleware()
            }
            Issue.record("Expected an anisette server error")
        } catch let error as OmnisetteError {
            let message = error.localizedDescription
            #expect(message.contains(server.absoluteString))
            #expect(message.contains("not anisette data"))
            #expect(message.contains("HTTP 200"))
        }
        #expect(fake.requestPaths.count == 3)
    }

    @Test func serverErrorObjectGivesServerMessageAndIsNotRetried() async throws {
        let fake = FakeAnisetteServer(status: 200, contentType: "application/json", body: """
            {"message":"provision.adi.ADIException: not provisioned (-45061)","result":"GetHeadersError"}
            """)
        do {
            _ = try await withAnisetteServer(fake) {
                try await sendThroughMiddleware()
            }
            Issue.record("Expected an anisette server error")
        } catch let error as OmnisetteError {
            let message = error.localizedDescription
            #expect(message.contains(server.absoluteString))
            #expect(message.contains("GetHeadersError"))
            #expect(message.contains("provision.adi.ADIException: not provisioned (-45061)"))
        }
        #expect(fake.requestPaths.count == 1)
    }

    @Test func incompleteReplyDoesNotShowTheTokens() async throws {
        // The reply has the one-time tokens, but not the routing information.
        let fake = FakeAnisetteServer(status: 200, contentType: "application/json", body: """
            {"result":"Headers","X-Apple-I-MD":"\(oneTimePassword)","X-Apple-I-MD-M":"\(machineID)"}
            """)
        do {
            _ = try await withAnisetteServer(fake) {
                try await sendThroughMiddleware()
            }
            Issue.record("Expected an anisette server error")
        } catch let error as OmnisetteError {
            #expect(error.localizedDescription.contains("not anisette data"))
            expectNoReplyValues(error.localizedDescription)
            expectNoReplyValues(String(describing: error))
            #expect(!error.isTransient)
        }
        #expect(fake.requestPaths.count == 1)
    }

    @Test func webSocketMessagesMapToTheSameErrors() throws {
        struct Request: Decodable {
            let cpim: Data
        }
        #expect(throws: OmnisetteError.self) {
            try OmnisetteADIProvider.decodeReply(Request.self, from: Data("not json".utf8), expectedResult: "GiveEndProvisioningData", server: server)
        }
        do {
            _ = try OmnisetteADIProvider.decodeReply(
                Request.self,
                from: Data(#"{"result":"StartProvisioningError","message":"bad spim"}"#.utf8),
                expectedResult: "GiveEndProvisioningData",
                server: server
            )
            Issue.record("Expected an anisette server error")
        } catch let error as OmnisetteError {
            #expect(error.localizedDescription.contains("StartProvisioningError: bad spim"))
            #expect(error.localizedDescription.contains(server.absoluteString))
            #expect(!error.isTransient)
        }
        let request = try OmnisetteADIProvider.decodeReply(
            Request.self,
            from: Data(#"{"result":"GiveEndProvisioningData","cpim":"AAEC"}"#.utf8),
            expectedResult: "GiveEndProvisioningData",
            server: server
        )
        #expect(request.cpim == Data([0, 1, 2]))
    }
}
