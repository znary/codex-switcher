//
//  AuthSnapshotStore.swift
//  multi-codex-limit-viewer
//

import Foundation

final class AuthSnapshotStore {
    private let fileManager = FileManager.default

    let rootURL: URL
    private let stateURL: URL
    private let accountsDirectoryURL: URL
    private let pendingLoginsDirectoryURL: URL

    init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? Self.defaultRootURL()
        self.rootURL = baseURL
        stateURL = baseURL.appendingPathComponent("app-state.json")
        accountsDirectoryURL = baseURL.appendingPathComponent("accounts", isDirectory: true)
        pendingLoginsDirectoryURL = baseURL.appendingPathComponent("pending-logins", isDirectory: true)

        try? fileManager.createDirectory(
            at: accountsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? fileManager.createDirectory(
            at: pendingLoginsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func loadState() throws -> PersistedAppState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder.codexMonitor.decode(PersistedAppState.self, from: data)
    }

    func saveState(_ state: PersistedAppState) throws {
        let data = try JSONEncoder.codexMonitor.encode(state)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: stateURL, options: .atomic)
    }

    func importCurrentAccount(existingAccounts: [StoredAccount]) throws -> StoredAccount {
        try importAccount(from: currentAuthURL(), existingAccounts: existingAccounts)
    }

    func importAccount(from authURL: URL, existingAccounts: [StoredAccount]) throws -> StoredAccount {
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw StoreError.authFileMissing(authURL.path)
        }

        let data = try Data(contentsOf: authURL)
        let authFile = try JSONDecoder().decode(ChatGPTAuthFile.self, from: data)
        let claims = try decodeClaims(from: authFile.tokens.idToken)
        let authClaims = claims.openAIAuth
        let accountID = authFile.tokens.accountID ?? authClaims.chatgptAccountID

        guard let accountID else {
            throw StoreError.invalidAuthFile("Missing ChatGPT account id in auth.json.")
        }

        let existingAccount = existingAccounts.first(where: { $0.id == accountID })
        let email = claims.email ?? claims.openAIProfile?.email ?? existingAccount?.email
        guard let email else {
            throw StoreError.invalidAuthFile("Missing email in auth.json.")
        }

        let workspaces = mergeWorkspaceDisplayTitles(
            makeWorkspaces(from: authClaims.organizations, accountID: accountID),
            existingWorkspaces: existingAccount?.workspaces ?? []
        )
        let selectedWorkspaceID = selectionID(
            from: existingAccount?.selectedWorkspaceID,
            available: workspaces
        )

        let accountDirectoryURL = accountsDirectoryURL.appendingPathComponent(accountID, isDirectory: true)
        try fileManager.createDirectory(
            at: accountDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let destinationURL = accountDirectoryURL.appendingPathComponent("auth.json")
        try copyAuthFile(data: data, to: destinationURL)

        return StoredAccount(
            id: accountID,
            provider: .chatGPTCodex,
            email: email,
            maskedEmail: maskEmailAddress(email),
            plan: PlanBadge(rawPlan: authClaims.chatgptPlanType ?? claims.planFromAccessToken),
            authHomeFolderName: accountID,
            workspaces: workspaces,
            selectedWorkspaceID: selectedWorkspaceID,
            importedAt: Date(),
            lastKnownRefreshAt: existingAccount?.lastKnownRefreshAt
        )
    }

    func codexHomeURL(for account: StoredAccount) -> URL {
        accountsDirectoryURL.appendingPathComponent(account.authHomeFolderName, isDirectory: true)
    }

    func storedAuthURL(for account: StoredAccount) -> URL {
        codexHomeURL(for: account).appendingPathComponent("auth.json")
    }

    func currentAuthURL() -> URL {
        currentCodexHomeURL().appendingPathComponent("auth.json")
    }

    func pendingLoginHomeURL() throws -> URL {
        let pendingHomeURL = pendingLoginsDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: pendingHomeURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return pendingHomeURL
    }

    func removePendingLoginHome(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func removeStoredAccount(_ account: StoredAccount) throws {
        let accountDirectoryURL = codexHomeURL(for: account)
        guard fileManager.fileExists(atPath: accountDirectoryURL.path) else {
            return
        }

        try fileManager.removeItem(at: accountDirectoryURL)
    }

    func activateAccount(_ account: StoredAccount) throws {
        let sourceURL = storedAuthURL(for: account)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StoreError.authFileMissing(sourceURL.path)
        }

        let data = try Data(contentsOf: sourceURL)
        let codexHomeURL = currentCodexHomeURL()
        try fileManager.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try copyAuthFile(data: data, to: currentAuthURL())
    }

    private func copyAuthFile(data: Data, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    private func currentCodexHomeURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func makeWorkspaces(
        from organizations: [OrganizationClaim],
        accountID: String
    ) -> [StoredWorkspace] {
        let workspaces = organizations.map { organization in
            StoredWorkspace(
                id: organization.id,
                title: organization.title,
                displayTitleOverride: nil,
                kind: organization.title.caseInsensitiveCompare("Personal") == .orderedSame ? .personal : .team,
                role: organization.role,
                isDefault: organization.isDefault
            )
        }

        guard !workspaces.isEmpty else {
            return [
                StoredWorkspace(
                    id: accountID,
                    title: "Personal",
                    displayTitleOverride: nil,
                    kind: .personal,
                    role: nil,
                    isDefault: true
                )
            ]
        }

        return workspaces.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func selectionID(from existingSelectionID: String?, available workspaces: [StoredWorkspace]) -> String {
        if let existingSelectionID, workspaces.contains(where: { $0.id == existingSelectionID }) {
            return existingSelectionID
        }

        if let defaultWorkspace = workspaces.first(where: \.isDefault) {
            return defaultWorkspace.id
        }

        return workspaces.first?.id ?? ""
    }

    func currentAccountID() throws -> String? {
        guard fileManager.fileExists(atPath: currentAuthURL().path) else {
            return nil
        }

        let data = try Data(contentsOf: currentAuthURL())
        let authFile = try JSONDecoder().decode(ChatGPTAuthFile.self, from: data)
        if let accountID = authFile.tokens.accountID {
            return accountID
        }

        let claims = try decodeClaims(from: authFile.tokens.idToken)
        return claims.openAIAuth.chatgptAccountID
    }

    private func mergeWorkspaceDisplayTitles(
        _ workspaces: [StoredWorkspace],
        existingWorkspaces: [StoredWorkspace]
    ) -> [StoredWorkspace] {
        let overridesByWorkspaceID: [String: String] = Dictionary(
            uniqueKeysWithValues: existingWorkspaces.compactMap { workspace in
                guard let displayTitleOverride = workspace.trimmedDisplayTitleOverride else {
                    return nil
                }
                return (workspace.id, displayTitleOverride)
            }
        )

        return workspaces.map { workspace in
            var updatedWorkspace = workspace
            if let displayTitleOverride = overridesByWorkspaceID[workspace.id] {
                updatedWorkspace.displayTitleOverride = displayTitleOverride
            }
            return updatedWorkspace
        }
    }

    private func decodeClaims(from jwt: String?) throws -> JWTClaims {
        guard
            let jwt,
            let payloadSegment = jwt.split(separator: ".").dropFirst().first,
            let payloadData = Data(base64URLEncoded: String(payloadSegment))
        else {
            throw StoreError.invalidAuthFile("Unable to decode id_token payload.")
        }

        return try JSONDecoder().decode(JWTClaims.self, from: payloadData)
    }

    private static func defaultRootURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("MultiCodexLimitViewer", isDirectory: true)
    }
}

extension AuthSnapshotStore {
    enum StoreError: LocalizedError {
        case authFileMissing(String)
        case invalidAuthFile(String)

        var errorDescription: String? {
            switch self {
            case .authFileMissing(let path):
                return "Could not find auth.json at \(path)."
            case .invalidAuthFile(let message):
                return message
            }
        }
    }
}

private struct ChatGPTAuthFile: Decodable {
    let tokens: ChatGPTAuthTokens
}

private struct ChatGPTAuthTokens: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

private struct JWTClaims: Decodable {
    let email: String?
    let openAIAuth: OpenAIAuthClaims
    let openAIProfile: ProfileClaims?

    var planFromAccessToken: String? {
        openAIAuth.chatgptPlanType
    }

    enum CodingKeys: String, CodingKey {
        case email
        case openAIAuth = "https://api.openai.com/auth"
        case openAIProfile = "https://api.openai.com/profile"
    }
}

private struct OpenAIAuthClaims: Decodable {
    let chatgptAccountID: String?
    let chatgptPlanType: String?
    let organizations: [OrganizationClaim]

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptPlanType = "chatgpt_plan_type"
        case organizations
    }
}

private struct ProfileClaims: Decodable {
    let email: String?
}

private struct OrganizationClaim: Decodable {
    let id: String
    let isDefault: Bool
    let role: String?
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case isDefault = "is_default"
        case role
        case title
    }
}

private extension JSONDecoder {
    static let codexMonitor: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let codexMonitor: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        self.init(base64Encoded: normalized)
    }
}
