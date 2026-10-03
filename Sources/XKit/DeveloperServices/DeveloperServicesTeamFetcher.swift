import Foundation

actor DeveloperServicesTeamFetcher {
    typealias Lookup = @Sendable (XcodeAuthData) async throws -> [DeveloperServicesTeam]

    static let shared = DeveloperServicesTeamFetcher()

    private var cache: [DeveloperServicesTeam.ID: Task<DeveloperServicesTeam, Error>] = [:]
    private let lookup: Lookup

    /// `lookup` is a test seam. The default lists the teams of the Xcode login.
    init(lookup: @escaping Lookup = { auth in
        let client = DeveloperServicesClient(authData: auth)
        return try await client.send(DeveloperServicesListTeamsRequest())
    }) {
        self.lookup = lookup
    }

    func teams(forXcodeLogin auth: XcodeAuthData) async throws -> DeveloperServicesTeam {
        let teamID = auth.teamID
        if let cached = cache[teamID] {
            return try await value(of: cached, teamID: teamID)
        }
        let lookup = self.lookup
        let task = Task {
            let teams = try await lookup(auth)
            guard let team = teams.first(where: { $0.id == teamID })
                  else { throw Errors.teamNotFound(teamID) }
            return team
        }
        cache[teamID] = task
        return try await value(of: task, teamID: teamID)
    }

    /// The cache keeps only successful lookups. A failed lookup, which includes a
    /// CancellationError, leaves the cache, so the next call starts a new lookup.
    /// Callers that already wait on the failed task receive the same error.
    private func value(
        of task: Task<DeveloperServicesTeam, Error>,
        teamID: DeveloperServicesTeam.ID
    ) async throws -> DeveloperServicesTeam {
        do {
            return try await task.value
        } catch {
            // Another caller can have started a new lookup already. Keep that one.
            if cache[teamID] == task {
                cache[teamID] = nil
            }
            throw error
        }
    }

    enum Errors: LocalizedError {
        case teamNotFound(DeveloperServicesTeam.ID)

        public var errorDescription: String? {
            switch self {
            case .teamNotFound(let id):
                return id.rawValue.withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "add_app_operation.error.team_not_found",
                            value: "A team with the ID '%s' could not be found. Please select another team.",
                            comment: ""
                        ), $0
                    )
                }
            }
        }
    }
}

extension XcodeAuthData {
    public func team() async throws -> DeveloperServicesTeam {
        try await DeveloperServicesTeamFetcher.shared.teams(forXcodeLogin: self)
    }
}

extension DeveloperAPIAuthData {
    public func team() async throws -> DeveloperServicesTeam? {
        switch self {
        case .appStoreConnect: nil
        case .xcode(let auth): try await auth.team()
        }
    }
}
