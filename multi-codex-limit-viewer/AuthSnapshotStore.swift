//
//  AuthSnapshotStore.swift
//  multi-codex-limit-viewer
//

import Foundation

struct CloudSyncStatus: Sendable {
    enum Phase: String, Sendable {
        case synced
        case syncing
        case different
        case localOnly
        case iCloudOnly
        case unavailable
        case empty
    }

    var phase: Phase
    var localStoragePath: String
    var iCloudStoragePath: String?
    var isICloudAvailable: Bool
    var trackedItemCount: Int
    var syncedItemCount: Int
    var localItemCount: Int
    var cloudItemCount: Int
    var lastConfirmedSyncAt: Date?
    var lastLocalChangeAt: Date?
    var lastCloudChangeAt: Date?
}

final class AuthSnapshotStore {
    private let fileManager = FileManager.default

    let rootURL: URL
    let localRootURL: URL
    let iCloudRootURL: URL?
    private let stateURL: URL
    private let accountsDirectoryURL: URL
    private let pendingLoginsDirectoryURL: URL
    private let localSettingsURL: URL

    init(rootURL: URL? = nil) {
        let localRootURL = rootURL ?? Self.localRootURL()
        self.localRootURL = localRootURL
        self.rootURL = localRootURL
        localSettingsURL = localRootURL.appendingPathComponent("sync-settings.json")
        iCloudRootURL = rootURL == nil ? Self.iCloudRootURL() : nil
        stateURL = localRootURL.appendingPathComponent("app-state.json")
        accountsDirectoryURL = localRootURL.appendingPathComponent("accounts", isDirectory: true)
        pendingLoginsDirectoryURL = localRootURL.appendingPathComponent("pending-logins", isDirectory: true)

        prepareDirectoriesIfNeeded()
        syncMissingLocalDataFromICloudIfNeeded()
        prepareDirectoriesIfNeeded()
    }

    func loadState() throws -> PersistedAppState {
        syncMissingLocalStateFromICloudIfNeeded()

        guard fileManager.fileExists(atPath: stateURL.path) else {
            return .empty
        }

        let data = try readData(at: stateURL)
        return try JSONDecoder.codexMonitor.decode(PersistedAppState.self, from: data)
    }

    func saveState(_ state: PersistedAppState) throws {
        let data = try JSONEncoder.codexMonitor.encode(state)
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try writeFile(data: data, to: stateURL)
    }

    func importCurrentAccount(existingAccounts: [StoredAccount]) throws -> StoredAccount {
        try importAccount(
            from: currentAuthURL(),
            existingAccounts: existingAccounts,
            missingFilePathDescription: "~/.codex/auth.json"
        )
    }

    func importAccount(
        from authURL: URL,
        existingAccounts: [StoredAccount],
        missingFilePathDescription: String? = nil
    ) throws -> StoredAccount {
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw StoreError.authFileMissing(missingFilePathDescription ?? authURL.path)
        }

        let data = try readData(at: authURL)
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
            lastKnownRefreshAt: existingAccount?.lastKnownRefreshAt,
            tags: existingAccount?.tags ?? []
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

    func prepareStoredAccountForUse(_ account: StoredAccount) {
        syncMissingLocalAuthFromICloudIfNeeded(accountHomeFolderName: account.authHomeFolderName)
    }

    func removeStoredAccount(_ account: StoredAccount) throws {
        let accountDirectoryURL = codexHomeURL(for: account)
        guard fileManager.fileExists(atPath: accountDirectoryURL.path) else {
            return
        }

        try fileManager.removeItem(at: accountDirectoryURL)
    }

    func activateAccount(_ account: StoredAccount) throws {
        syncMissingLocalAuthFromICloudIfNeeded(accountHomeFolderName: account.authHomeFolderName)

        let sourceURL = storedAuthURL(for: account)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw StoreError.authFileMissing(sourceURL.path)
        }

        let data = try readData(at: sourceURL)
        let codexHomeURL = currentCodexHomeURL()
        try fileManager.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try copyAuthFile(data: data, to: currentAuthURL())
    }

    func currentAccountID() throws -> String? {
        guard fileManager.fileExists(atPath: currentAuthURL().path) else {
            return nil
        }

        let data = try readData(at: currentAuthURL())
        let authFile = try JSONDecoder().decode(ChatGPTAuthFile.self, from: data)
        if let accountID = authFile.tokens.accountID {
            return accountID
        }

        let claims = try decodeClaims(from: authFile.tokens.idToken)
        return claims.openAIAuth.chatgptAccountID
    }

    func cloudSyncStatus() -> CloudSyncStatus {
        let localSettings = loadLocalSettings()
        let trackedItems = trackedSyncItems()
        let syncedItemCount = trackedItems.filter(\.isMatched).count
        let localItemCount = trackedItems.filter(\.localExists).count
        let cloudItemCount = trackedItems.filter(\.cloudExists).count
        let hasPendingCloudTransfers = trackedItems.contains { $0.cloudExists && !$0.isCloudCurrent }
        let lastLocalChangeAt = trackedItems.compactMap(\.localModificationDate).max()
        let lastCloudChangeAt = trackedItems.compactMap(\.cloudModificationDate).max()

        let phase: CloudSyncStatus.Phase
        if iCloudRootURL == nil {
            phase = .unavailable
        } else if trackedItems.isEmpty {
            phase = .empty
        } else if hasPendingCloudTransfers {
            phase = .syncing
        } else if syncedItemCount == trackedItems.count {
            phase = .synced
        } else if cloudItemCount == 0 {
            phase = .localOnly
        } else if localItemCount == 0 {
            phase = .iCloudOnly
        } else {
            phase = .different
        }

        return CloudSyncStatus(
            phase: phase,
            localStoragePath: localRootURL.path,
            iCloudStoragePath: iCloudRootURL?.path,
            isICloudAvailable: iCloudRootURL != nil,
            trackedItemCount: trackedItems.count,
            syncedItemCount: syncedItemCount,
            localItemCount: localItemCount,
            cloudItemCount: cloudItemCount,
            lastConfirmedSyncAt: localSettings.lastConfirmedSyncAt,
            lastLocalChangeAt: lastLocalChangeAt,
            lastCloudChangeAt: lastCloudChangeAt
        )
    }

    func overwriteLocalDataFromICloud() throws {
        guard let iCloudRootURL else {
            throw StoreError.iCloudUnavailable
        }

        try replacePersistentSnapshot(
            sourceRootURL: iCloudRootURL,
            destinationRootURL: localRootURL
        )
        try markSyncCompleted()
    }

    func overwriteICloudDataFromLocal() throws {
        guard let iCloudRootURL else {
            throw StoreError.iCloudUnavailable
        }

        try replacePersistentSnapshot(
            sourceRootURL: localRootURL,
            destinationRootURL: iCloudRootURL
        )
        try markSyncCompleted()
    }

    func deleteICloudStorage() throws {
        guard let iCloudRootURL else {
            throw StoreError.iCloudUnavailable
        }

        let cloudStateURL = iCloudRootURL.appendingPathComponent("app-state.json")
        let cloudAccountsDirectoryURL = iCloudRootURL.appendingPathComponent("accounts", isDirectory: true)

        if fileManager.fileExists(atPath: cloudStateURL.path) {
            try fileManager.removeItem(at: cloudStateURL)
        }

        if fileManager.fileExists(atPath: cloudAccountsDirectoryURL.path) {
            try fileManager.removeItem(at: cloudAccountsDirectoryURL)
        }

        var localSettings = loadLocalSettings()
        localSettings.lastConfirmedSyncAt = nil
        try saveLocalSettings(localSettings)
    }

    private func copyAuthFile(data: Data, to destinationURL: URL) throws {
        try writeFile(data: data, to: destinationURL)
    }

    private func writeFile(data: Data, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    private func readData(at url: URL) throws -> Data {
        ensureUbiquitousDownloadStarted(at: url)
        return try Data(contentsOf: url)
    }

    private func ensureUbiquitousDownloadStarted(at url: URL) {
        guard let iCloudRootURL else {
            return
        }
        guard url.path.hasPrefix(iCloudRootURL.path) else {
            return
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let resourceValues = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard resourceValues?.isUbiquitousItem == true else {
            return
        }

        if resourceValues?.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
    }

    private func currentCodexHomeURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private func prepareDirectoriesIfNeeded() {
        try? fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
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

    private func syncMissingLocalDataFromICloudIfNeeded() {
        let didCopyState = syncMissingLocalStateFromICloudIfNeeded()
        let didCopyAccounts = syncMissingLocalAccountsFromICloudIfNeeded()
        if didCopyState || didCopyAccounts {
            try? markSyncCompleted()
        }
    }

    @discardableResult
    private func syncMissingLocalStateFromICloudIfNeeded() -> Bool {
        copyFromICloudIfLocalMissing(relativePath: "app-state.json")
    }

    @discardableResult
    private func syncMissingLocalAuthFromICloudIfNeeded(accountHomeFolderName: String) -> Bool {
        copyFromICloudIfLocalMissing(relativePath: authRelativePath(for: accountHomeFolderName))
    }

    @discardableResult
    private func syncMissingLocalAccountsFromICloudIfNeeded() -> Bool {
        guard let iCloudRootURL else {
            return false
        }

        let cloudAccountHomeFolderNames = accountHomeFolderNames(in: iCloudRootURL)
        guard !cloudAccountHomeFolderNames.isEmpty else {
            return false
        }

        var didCopyAny = false
        for accountHomeFolderName in cloudAccountHomeFolderNames {
            if syncMissingLocalAuthFromICloudIfNeeded(accountHomeFolderName: accountHomeFolderName) {
                didCopyAny = true
            }
        }
        return didCopyAny
    }

    @discardableResult
    private func copyFromICloudIfLocalMissing(relativePath: String) -> Bool {
        guard let iCloudRootURL else {
            return false
        }

        let localURL = localRootURL.appendingPathComponent(relativePath)
        guard !fileManager.fileExists(atPath: localURL.path) else {
            return false
        }

        let cloudURL = iCloudRootURL.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: cloudURL.path) else {
            return false
        }

        do {
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try readRawData(at: cloudURL)
            try writeFile(data: data, to: localURL)
            return true
        } catch {
            return false
        }
    }

    private func accountHomeFolderNames(in rootURL: URL) -> [String] {
        let accountsDirectoryURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        let accountDirectories = (try? fileManager.contentsOfDirectory(
            at: accountsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return accountDirectories.compactMap { accountDirectoryURL in
            let authURL = accountDirectoryURL.appendingPathComponent("auth.json")
            guard fileManager.fileExists(atPath: authURL.path) else {
                return nil
            }
            return accountDirectoryURL.lastPathComponent
        }
    }

    private func trackedSyncItems() -> [TrackedSyncItem] {
        let localRelativePaths = persistentRelativePaths(in: localRootURL)
        let cloudRelativePaths = persistentRelativePaths(in: iCloudRootURL)
        let allRelativePaths = Array(localRelativePaths.union(cloudRelativePaths)).sorted()
        return allRelativePaths.map(trackedSyncItem(for:))
    }

    private func persistentRelativePaths(in rootURL: URL?) -> Set<String> {
        guard let rootURL else {
            return []
        }

        var relativePaths: Set<String> = []
        let stateURL = rootURL.appendingPathComponent("app-state.json")
        if fileManager.fileExists(atPath: stateURL.path) {
            relativePaths.insert("app-state.json")
        }

        for accountHomeFolderName in accountHomeFolderNames(in: rootURL) {
            relativePaths.insert(authRelativePath(for: accountHomeFolderName))
        }

        return relativePaths
    }

    private func trackedSyncItem(for relativePath: String) -> TrackedSyncItem {
        let localURL = localRootURL.appendingPathComponent(relativePath)
        let cloudURL = iCloudRootURL?.appendingPathComponent(relativePath)
        let localExists = fileManager.fileExists(atPath: localURL.path)
        let cloudExists = cloudURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

        let localModificationDate = try? localURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let cloudModificationDate = cloudURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        let localData = localExists ? (try? Data(contentsOf: localURL)) : nil
        let cloudData = cloudExists ? cloudURL.flatMap { try? readRawData(at: $0) } : nil

        let cloudResourceValues = cloudURL.flatMap {
            try? $0.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemIsUploadingKey,
                .ubiquitousItemIsDownloadingKey,
                .ubiquitousItemDownloadingStatusKey
            ])
        }
        let isCloudCurrent: Bool = {
            guard cloudExists else {
                return true
            }

            guard cloudResourceValues?.isUbiquitousItem == true else {
                return true
            }

            return cloudResourceValues?.ubiquitousItemIsUploaded == true
                && cloudResourceValues?.ubiquitousItemIsUploading != true
                && cloudResourceValues?.ubiquitousItemIsDownloading != true
                && cloudResourceValues?.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current
        }()

        return TrackedSyncItem(
            relativePath: relativePath,
            localExists: localExists,
            cloudExists: cloudExists,
            isMatched: localExists && cloudExists && localData == cloudData,
            isCloudCurrent: isCloudCurrent,
            localModificationDate: localModificationDate,
            cloudModificationDate: cloudModificationDate
        )
    }

    private func replacePersistentSnapshot(
        sourceRootURL: URL,
        destinationRootURL: URL
    ) throws {
        let sourceStateURL = sourceRootURL.appendingPathComponent("app-state.json")
        let sourceAccountsDirectoryURL = sourceRootURL.appendingPathComponent("accounts", isDirectory: true)
        let destinationStateURL = destinationRootURL.appendingPathComponent("app-state.json")
        let destinationAccountsDirectoryURL = destinationRootURL.appendingPathComponent("accounts", isDirectory: true)

        try fileManager.createDirectory(
            at: destinationRootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if fileManager.fileExists(atPath: destinationAccountsDirectoryURL.path) {
            try fileManager.removeItem(at: destinationAccountsDirectoryURL)
        }
        try fileManager.createDirectory(
            at: destinationAccountsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if fileManager.fileExists(atPath: sourceStateURL.path) {
            let stateData = try readRawData(at: sourceStateURL)
            try writeFile(data: stateData, to: destinationStateURL)
        } else if fileManager.fileExists(atPath: destinationStateURL.path) {
            try fileManager.removeItem(at: destinationStateURL)
        }

        let sourceAccountHomeFolderNames = accountHomeFolderNames(in: sourceRootURL)
        for accountHomeFolderName in sourceAccountHomeFolderNames {
            let sourceAuthURL = sourceAccountsDirectoryURL
                .appendingPathComponent(accountHomeFolderName, isDirectory: true)
                .appendingPathComponent("auth.json")
            let destinationAccountDirectoryURL = destinationAccountsDirectoryURL
                .appendingPathComponent(accountHomeFolderName, isDirectory: true)
            let destinationAuthURL = destinationAccountDirectoryURL.appendingPathComponent("auth.json")

            try fileManager.createDirectory(
                at: destinationAccountDirectoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try readRawData(at: sourceAuthURL)
            try copyAuthFile(data: data, to: destinationAuthURL)
        }
    }

    private func readRawData(at url: URL) throws -> Data {
        ensureUbiquitousDownloadStarted(at: url)
        return try Data(contentsOf: url)
    }

    private func markSyncCompleted() throws {
        var localSettings = loadLocalSettings()
        localSettings.lastConfirmedSyncAt = Date()
        try saveLocalSettings(localSettings)
    }

    private func loadLocalSettings() -> LocalStoreSettings {
        Self.loadLocalSettings(from: localSettingsURL)
    }

    private func saveLocalSettings(_ settings: LocalStoreSettings) throws {
        let data = try JSONEncoder.codexMonitor.encode(settings)
        try fileManager.createDirectory(
            at: localRootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try writeFile(data: data, to: localSettingsURL)
    }

    private static func loadLocalSettings(from url: URL) -> LocalStoreSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LocalStoreSettings()
        }

        guard let data = try? Data(contentsOf: url) else {
            return LocalStoreSettings()
        }

        return (try? JSONDecoder.codexMonitor.decode(LocalStoreSettings.self, from: data))
            ?? LocalStoreSettings()
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

    private func authRelativePath(for accountHomeFolderName: String) -> String {
        "accounts/\(accountHomeFolderName)/auth.json"
    }

    private static func localRootURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL.appendingPathComponent("MultiCodexLimitViewer", isDirectory: true)
    }

    private static func iCloudRootURL() -> URL? {
        guard let ubiquityContainerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }

        return ubiquityContainerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MultiCodexLimitViewer", isDirectory: true)
    }
}

extension AuthSnapshotStore {
    enum StoreError: LocalizedError {
        case authFileMissing(String)
        case invalidAuthFile(String)
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .authFileMissing(let path):
                return "Could not find auth.json at \(path)."
            case .invalidAuthFile(let message):
                return message
            case .iCloudUnavailable:
                return "iCloud storage is unavailable on this Mac."
            }
        }
    }
}

private struct LocalStoreSettings: Codable {
    var lastConfirmedSyncAt: Date?
}

private struct TrackedSyncItem {
    let relativePath: String
    let localExists: Bool
    let cloudExists: Bool
    let isMatched: Bool
    let isCloudCurrent: Bool
    let localModificationDate: Date?
    let cloudModificationDate: Date?
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
    init?(base64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        self.init(base64Encoded: normalized)
    }
}
