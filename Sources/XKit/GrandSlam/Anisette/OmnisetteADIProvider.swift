import Foundation
import Dependencies

/// A failure of the anisette server.
///
/// The messages never contain a reply body, because a successful reply
/// contains one-time Apple tokens (`X-Apple-I-MD`, `X-Apple-I-MD-M`).
public enum OmnisetteError: LocalizedError, Sendable {
    /// The server replied with an HTTP status that is not 2xx.
    case httpStatus(server: URL, status: Int)
    /// The reply is not valid JSON, or it does not have the expected fields.
    /// `status` and `contentType` are nil for a WebSocket message.
    case invalidReply(server: URL, status: Int?, contentType: String?, isJSON: Bool)
    /// The server sent a JSON error object.
    case serverError(server: URL, result: String, message: String?)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let server, let status):
            return "The anisette server \(server.absoluteString) returned HTTP status \(status)."
        case .invalidReply(let server, let status, let contentType, _):
            let source: String
            if let status {
                source = "HTTP \(status), content type \(contentType ?? "not set")"
            } else {
                source = "WebSocket message"
            }
            return "The anisette server \(server.absoluteString) sent a reply that is not anisette data (\(source))."
        case .serverError(let server, let result, let message):
            guard let message else {
                return "The anisette server \(server.absoluteString) reported an error: \(result)."
            }
            return "The anisette server \(server.absoluteString) reported an error: \(result): \(message)"
        }
    }

    /// True when a second attempt can succeed: a server failure (5xx) or a reply
    /// that is not JSON. A JSON error object gives the same result again.
    public var isTransient: Bool {
        switch self {
        case .httpStatus(_, let status):
            return (500...599).contains(status)
        case .invalidReply(_, _, _, let isJSON):
            return !isJSON
        case .serverError:
            return false
        }
    }
}

struct OmnisetteADIProvider: RawADIProvider {
    @Dependency(\.httpClient) private var client

    // should implement v3 of https://github.com/SideStore/omnisette-server
    // list: https://servers.sidestore.io/servers.json
    // e.g. https://ani.sidestore.io
    private let url: URL
    init(
        url: URL = URL(string: "https://ani.sidestore.io")! // URL(string: "http://localhost:6969")!
    ) {
        self.url = url
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    /// The `result` and `message` fields that each server reply can have.
    private struct ReplyHeader: Decodable {
        let result: String?
        let message: String?
    }

    // A server message is diagnostic text. Keep a long one from filling the log.
    private static let maximumMessageLength = 300

    /// Decodes a reply of the server at `server`. A reply whose `result` is not
    /// `expectedResult` is a JSON error object. Use a nil `expectedResult` for a
    /// reply that has no `result` field.
    /// Each failure becomes an `OmnisetteError`, which does not contain the body.
    static func decodeReply<T: Decodable>(
        _ type: T.Type,
        from body: Data,
        expectedResult: String?,
        server: URL,
        status: Int? = nil,
        contentType: String? = nil
    ) throws -> T {
        let header: ReplyHeader
        do {
            header = try decoder.decode(ReplyHeader.self, from: body)
        } catch {
            let isJSON = (try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)) != nil
            throw OmnisetteError.invalidReply(server: server, status: status, contentType: contentType, isJSON: isJSON)
        }
        if let result = header.result, result != expectedResult {
            throw OmnisetteError.serverError(
                server: server,
                result: String(result.prefix(maximumMessageLength)),
                message: header.message.map { String($0.prefix(maximumMessageLength)) }
            )
        }
        guard expectedResult == nil || header.result != nil else {
            throw OmnisetteError.invalidReply(server: server, status: status, contentType: contentType, isJSON: true)
        }
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw OmnisetteError.invalidReply(server: server, status: status, contentType: contentType, isJSON: true)
        }
    }

    /// Checks the HTTP status before it decodes the reply.
    private func decodeReply<T: Decodable>(
        _ type: T.Type,
        response: HTTPResponse,
        body: Data,
        expectedResult: String?
    ) throws -> T {
        guard response.status.kind == .successful else {
            throw OmnisetteError.httpStatus(server: url, status: response.status.code)
        }
        return try Self.decodeReply(
            type,
            from: body,
            expectedResult: expectedResult,
            server: url,
            status: response.status.code,
            contentType: response.headerFields[.contentType]
        )
    }

    func clientInfo() async throws -> String {
        struct ClientInfo: Decodable {
            let clientInfo: String
        }
        let (response, body) = try await client.makeRequest(
            HTTPRequest(url: url.appendingPathComponent("v3/client_info"))
        )
        let clientInfo = try decodeReply(ClientInfo.self, response: response, body: body, expectedResult: nil)
        return clientInfo.clientInfo
    }

    func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
        var url = url.appendingPathComponent("v3/provisioning_session")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        url = components.url!

        let task = try await client.makeWebSocket(url: url)
        let connection = OmnisetteProvisioningSession(task: task, server: self.url)
        let cpim = try await connection.startProvisioning(spim: spim, userID: userID)
        return (connection, cpim)
    }

    func requestOTP(
        userID: UUID,
        routingInfo: inout UInt64,
        provisioningInfo: Data
    ) async throws -> (machineID: Data, otp: Data) {
        struct Request: Encodable {
            let identifier: Data
            let adiPb: Data
        }

        struct Response: Decodable {
            var machineID: Data
            var otp: Data
            var rinfo: String

            private enum CodingKeys: String, CodingKey {
                case machineID = "X-Apple-I-MD-M"
                case otp = "X-Apple-I-MD"
                case rinfo = "X-Apple-I-MD-RINFO"
            }
        }

        var request = HTTPRequest(url: url.appendingPathComponent("v3/get_headers"))
        request.method = .post
        request.headerFields[.contentType] = "application/json"
        let body = try Self.encoder.encode(Request(
            identifier: userID.rawBytes,
            adiPb: provisioningInfo
        ))
        let (response, responseBody) = try await client.makeRequest(request, body: body)
        let decoded = try decodeReply(Response.self, response: response, body: responseBody, expectedResult: "Headers")
        if let rinfo = UInt64(decoded.rinfo) {
            routingInfo = rinfo
        }
        return (decoded.machineID, decoded.otp)
    }
}

private final class OmnisetteProvisioningSession: RawADIProvisioningSession {
    let task: WebSocketSession
    let server: URL

    init(task: WebSocketSession, server: URL) {
        self.task = task
        self.server = server
    }

    deinit {
        close()
    }

    private func close() {
        task.close()
    }

    func startProvisioning(
        spim: Data,
        userID: UUID
    ) async throws -> Data {
        do {
            struct Response: Encodable {
                let identifier: Data
            }
            try await receive("GiveIdentifier")
            try await send(Response(identifier: userID.rawBytes))
        }

        do {
            struct Response: Encodable {
                let spim: Data
            }
            try await receive("GiveStartProvisioningData")
            try await send(Response(spim: spim))
        }

        do {
            struct Request: Decodable {
                let cpim: Data
            }
            return try await receive("GiveEndProvisioningData", as: Request.self).cpim
        }
    }

    func endProvisioning(routingInfo: UInt64, ptm: Data, tk: Data) async throws -> Data {
        defer { close() }
        do {
            struct Response: Encodable {
                let ptm: Data
                let tk: Data
            }
            try await send(Response(ptm: ptm, tk: tk))
        }

        do {
            struct Request: Decodable {
                let adiPb: Data
            }
            return try await receive("ProvisioningSuccess", as: Request.self).adiPb
        }
    }

    @discardableResult
    private func receive<T: Decodable>(_ message: String, as type: T.Type = EmptyResponse.self) async throws -> T {
        let data = switch try await task.receive() {
        case .data(let data): data
        case .text(let text): Data(text.utf8)
        @unknown default: Data()
        }
        return try OmnisetteADIProvider.decodeReply(type, from: data, expectedResult: message, server: server)
    }

    private func send<T: Encodable>(_ message: T) async throws {
        let encoded = try OmnisetteADIProvider.encoder.encode(message)
        try await task.send(.text(String(decoding: encoded, as: UTF8.self)))
    }
}

extension UUID {
    fileprivate var rawBytes: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
