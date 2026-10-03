import Foundation
import Testing
@testable import XKit

private let auth = XcodeAuthData(
    loginToken: DeveloperServicesLoginToken(adsid: "ADSID", token: "GS-TOKEN", expiry: .distantFuture),
    teamID: DeveloperServicesTeam.ID(rawValue: "TEAM")
)

private func makeTeam() throws -> DeveloperServicesTeam {
    let json = #"{"teamId":"TEAM","status":"active","name":"Team","memberships":[]}"#
    return try JSONDecoder().decode(DeveloperServicesTeam.self, from: Data(json.utf8))
}

/// Counts the lookups. The first `failures` lookups throw `error`.
private final class FakeTeamLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failures: Int
    private let error: any Error

    init(failures: Int = 0, error: any Error = URLError(.badServerResponse)) {
        self.failures = failures
        self.error = error
    }

    var lookups: Int {
        lock.withLock { count }
    }

    func lookup(_ auth: XcodeAuthData) throws -> [DeveloperServicesTeam] {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        if attempt <= failures {
            throw error
        }
        return [try makeTeam()]
    }
}

struct DeveloperServicesTeamFetcherTests {
    @Test func failedLookupIsNotCached() async throws {
        let fake = FakeTeamLookup(failures: 1)
        let fetcher = DeveloperServicesTeamFetcher { try fake.lookup($0) }
        await #expect(throws: URLError.self) {
            try await fetcher.teams(forXcodeLogin: auth)
        }
        let team = try await fetcher.teams(forXcodeLogin: auth)
        #expect(team.id == auth.teamID)
        #expect(fake.lookups == 2)
    }

    @Test func successfulLookupIsCached() async throws {
        let fake = FakeTeamLookup()
        let fetcher = DeveloperServicesTeamFetcher { try fake.lookup($0) }
        _ = try await fetcher.teams(forXcodeLogin: auth)
        let team = try await fetcher.teams(forXcodeLogin: auth)
        #expect(team.id == auth.teamID)
        #expect(fake.lookups == 1)
    }

    @Test func cancellationIsNotCached() async throws {
        let fake = FakeTeamLookup(failures: 1, error: CancellationError())
        let fetcher = DeveloperServicesTeamFetcher { try fake.lookup($0) }
        await #expect(throws: CancellationError.self) {
            try await fetcher.teams(forXcodeLogin: auth)
        }
        _ = try await fetcher.teams(forXcodeLogin: auth)
        #expect(fake.lookups == 2)
    }

    @Test func missingTeamIsNotCached() async throws {
        let fetcher = DeveloperServicesTeamFetcher { _ in [] }
        for _ in 0..<2 {
            await #expect(throws: DeveloperServicesTeamFetcher.Errors.self) {
                try await fetcher.teams(forXcodeLogin: auth)
            }
        }
    }
}
