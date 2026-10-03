import Foundation

/// Retries a transient failure of the anisette server: a 5xx status, or a reply
/// that is not JSON. The server can fail for some seconds at a time.
enum AnisetteServerRetry {
    /// The wait before each new attempt. The total is 7 seconds, so a deploy does
    /// not wait for minutes when the server is down. Tests can set other values.
    @TaskLocal static var delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Fetches anisette data from `provider`. After the last attempt, it throws the
    /// last OmnisetteError, which names the server and the HTTP status.
    static func fetch(from provider: any AnisetteDataProvider) async throws -> AnisetteData {
        var remainingDelays = delays[...]
        while true {
            do {
                return try await provider.fetchAnisetteData()
            } catch let error as OmnisetteError where error.isTransient {
                guard let delay = remainingDelays.popFirst() else {
                    throw error
                }
                try await Task.sleep(for: delay)
            }
        }
    }
}
