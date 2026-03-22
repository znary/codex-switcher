//
//  MenuBarViewModel.swift
//  multi-codex-limit-viewer
//

import AppKit
import Combine
import Foundation

@MainActor
final class MenuBarViewModel: ObservableObject {
    @Published private(set) var state: PersistedAppState
    @Published private(set) var runtimeStates: [String: AccountRuntimeState]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAddingAccount = false
    @Published var transientError: String?
    @Published private(set) var codexExecutablePath: String?
    @Published private(set) var diagnosticsReport = ""

    private let store: AuthSnapshotStore
    private let probe: CodexUsageProbe
    private let loginFlow: CodexLoginFlow
    private let resolver: CodexExecutableResolver
    private let logger: DiagnosticsLogStore
    private var autoRefreshTask: Task<Void, Never>?

    init(
        store: AuthSnapshotStore? = nil,
        probe: CodexUsageProbe? = nil,
        loginFlow: CodexLoginFlow? = nil,
        resolver: CodexExecutableResolver? = nil,
        logger: DiagnosticsLogStore? = nil
    ) {
        self.store = store ?? AuthSnapshotStore()
        self.probe = probe ?? CodexUsageProbe()
        self.loginFlow = loginFlow ?? CodexLoginFlow()
        self.resolver = resolver ?? CodexExecutableResolver()
        self.logger = logger ?? DiagnosticsLogStore(rootURL: self.store.rootURL)
        state = (try? self.store.loadState()) ?? .empty
        runtimeStates = [:]
        self.logger.append("App launched. storage=\(self.store.rootURL.path)")
        refreshDiagnosticsReport()

        Task {
            await bootstrap()
        }
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    var accounts: [StoredAccount] {
        state.accounts
    }

    var activeAccount: StoredAccount? {
        if let activeAccountID = state.activeAccountID,
           let matchingAccount = state.accounts.first(where: { $0.id == activeAccountID }) {
            return matchingAccount
        }
        return state.accounts.first
    }

    var activeWorkspace: StoredWorkspace? {
        guard let activeAccount else {
            return nil
        }
        return activeAccount.selectedWorkspace
    }

    var activeSnapshot: UsageSnapshot? {
        guard let activeAccount else {
            return nil
        }
        return snapshot(for: activeAccount, workspaceID: activeAccount.selectedWorkspaceID)
    }

    var storagePath: String {
        store.rootURL.path
    }

    var diagnosticsLogPath: String {
        logger.logURL.path
    }

    func bootstrap() async {
        log("Bootstrapping app. importedAccounts=\(state.accounts.count)")

        if state.accounts.isEmpty {
            do {
                _ = try importCurrentAccountSync(setActive: true)
            } catch {
                transientError = error.localizedDescription
                log("Bootstrap import failed: \(error.localizedDescription)")
            }
        }

        await refreshAll()
        startAutoRefreshLoop()
        log("Bootstrap finished.")
    }

    func addAccount() async {
        guard !isAddingAccount else {
            log("Add Account skipped because an add-account flow is already running.")
            return
        }

        isAddingAccount = true
        defer {
            isAddingAccount = false
        }

        do {
            let currentAccountImport = try importCurrentAccountSync(setActive: false)
            if currentAccountImport.wasNew {
                updateState { state in
                    state.activeAccountID = currentAccountImport.account.id
                }
                log("Added current Codex account \(currentAccountImport.account.maskedEmail).")
                await refreshAll()
                return
            }

            let codexExecutable = try resolver.resolve(log: logger.append)
            codexExecutablePath = codexExecutable.path
            log("Using codex executable for Add Account: \(codexExecutable.path)")

            let pendingLoginHomeURL = try store.pendingLoginHomeURL()
            defer {
                store.removePendingLoginHome(at: pendingLoginHomeURL)
            }

            try await loginFlow.login(
                executableURL: codexExecutable,
                codexHomeURL: pendingLoginHomeURL,
                log: logger.append
            )

            let authURL = pendingLoginHomeURL.appendingPathComponent("auth.json")
            let importedAccount = try store.importAccount(
                from: authURL,
                existingAccounts: state.accounts
            )
            let addAccountResult = upsertImportedAccount(importedAccount, setActive: true)
            log("Added browser account \(addAccountResult.account.maskedEmail).")
            await refreshAll()
        } catch {
            transientError = error.localizedDescription
            log("Add Account failed: \(error.localizedDescription)")
        }
    }

    func refreshAll() async {
        guard !state.accounts.isEmpty, !isRefreshing else {
            if state.accounts.isEmpty {
                log("Refresh skipped because there are no imported accounts.")
            } else {
                log("Refresh skipped because a refresh is already running.")
            }
            return
        }

        isRefreshing = true
        transientError = nil
        log("Refresh started. accounts=\(state.accounts.count)")

        for account in state.accounts {
            var runtimeState = runtimeStates[account.id] ?? AccountRuntimeState()
            runtimeState.isLoading = true
            runtimeStates[account.id] = runtimeState
        }

        do {
            let codexExecutable = try resolver.resolve(log: logger.append)
            codexExecutablePath = codexExecutable.path
            log("Using codex executable: \(codexExecutable.path)")

            let jobs = state.accounts.flatMap { account in
                account.workspaces.map { workspace in
                    RefreshJob(
                        accountID: account.id,
                        workspaceID: workspace.id,
                        homeURL: store.codexHomeURL(for: account)
                    )
                }
            }

            let logger = self.logger
            let probe = self.probe

            let outcomes = await withTaskGroup(of: RefreshOutcome.self) { group in
                for job in jobs {
                    group.addTask {
                        let scope = "account=\(job.accountID) workspace=\(job.workspaceID)"
                        do {
                            let result = try await probe.fetchSnapshot(
                                executableURL: codexExecutable,
                                codexHomeURL: job.homeURL,
                                workspaceID: job.workspaceID,
                                log: { message in
                                    logger.append("[\(scope)] \(message)")
                                }
                            )
                            return RefreshOutcome(
                                accountID: job.accountID,
                                workspaceID: job.workspaceID,
                                result: .success(result)
                            )
                        } catch {
                            logger.append("[\(scope)] Refresh failed: \(error.localizedDescription)")
                            return RefreshOutcome(
                                accountID: job.accountID,
                                workspaceID: job.workspaceID,
                                result: .failure(error.localizedDescription)
                            )
                        }
                    }
                }

                var collected: [RefreshOutcome] = []
                for await outcome in group {
                    collected.append(outcome)
                }
                return collected
            }

            apply(outcomes: outcomes)
            try saveState()
            let failureCount = outcomes.filter {
                if case .failure = $0.result {
                    return true
                }
                return false
            }.count
            log("Refresh finished. jobs=\(outcomes.count) failures=\(failureCount)")
        } catch {
            transientError = error.localizedDescription
            log("Refresh failed before probes completed: \(error.localizedDescription)")
            for account in state.accounts {
                var runtimeState = runtimeStates[account.id] ?? AccountRuntimeState()
                runtimeState.isLoading = false
                runtimeState.lastError = error.localizedDescription
                runtimeStates[account.id] = runtimeState
            }
        }

        isRefreshing = false
        refreshDiagnosticsReport()
    }

    func selectAccount(_ accountID: String) {
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        transientError = nil

        do {
            try store.activateAccount(account)
            updateState { state in
                state.activeAccountID = accountID
            }
            log("Switched Codex to account \(account.maskedEmail).")
        } catch {
            transientError = error.localizedDescription
            log("Switch account failed: \(error.localizedDescription)")
        }
    }

    func selectWorkspace(_ workspaceID: String, for accountID: String) {
        guard state.accounts.contains(where: { $0.id == accountID }) else {
            return
        }

        updateState { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                return
            }
            state.accounts[index].selectedWorkspaceID = workspaceID
            state.activeAccountID = accountID
        }
    }

    func toggleShowEmails() {
        updateState { state in
            state.showEmails.toggle()
        }
    }

    func displayedEmail(for account: StoredAccount) -> String {
        state.showEmails ? account.email : account.maskedEmail
    }

    func copyDiagnostics() {
        let report = buildDiagnosticsReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        log("Copied diagnostics to clipboard.")
    }

    func revealDiagnosticsLog() {
        NSWorkspace.shared.activateFileViewerSelecting([logger.logURL])
        log("Revealed diagnostics log in Finder.")
    }

    func snapshot(for account: StoredAccount, workspaceID: String? = nil) -> UsageSnapshot? {
        let runtimeState = runtimeStates[account.id]
        if let workspaceID,
           let snapshot = runtimeState?.snapshotsByWorkspaceID[workspaceID] {
            return snapshot
        }

        if let selectedSnapshot = runtimeState?.snapshotsByWorkspaceID[account.selectedWorkspaceID] {
            return selectedSnapshot
        }

        return runtimeState?.snapshotsByWorkspaceID.values.first
    }

    func runtimeState(for accountID: String) -> AccountRuntimeState {
        runtimeStates[accountID] ?? AccountRuntimeState()
    }

    private func apply(outcomes: [RefreshOutcome]) {
        var updatedAccounts = state.accounts

        for accountIndex in updatedAccounts.indices {
            let accountID = updatedAccounts[accountIndex].id
            var runtimeState = runtimeStates[accountID] ?? AccountRuntimeState()
            runtimeState.isLoading = false
            runtimeState.lastError = nil

            let relevantOutcomes = outcomes.filter { $0.accountID == accountID }
            for outcome in relevantOutcomes {
                switch outcome.result {
                case .success(let probeResult):
                    updatedAccounts[accountIndex].email = probeResult.email
                    updatedAccounts[accountIndex].maskedEmail = maskEmailAddress(probeResult.email)
                    updatedAccounts[accountIndex].plan = probeResult.plan
                    if let workspaces = probeResult.workspaces, !workspaces.isEmpty {
                        updatedAccounts[accountIndex].workspaces = workspaces
                        updatedAccounts[accountIndex].selectedWorkspaceID = preferredWorkspaceID(
                            existingSelectionID: updatedAccounts[accountIndex].selectedWorkspaceID,
                            available: workspaces
                        )
                    }
                    updatedAccounts[accountIndex].lastKnownRefreshAt = probeResult.snapshot.capturedAt
                    runtimeState.snapshotsByWorkspaceID[outcome.workspaceID] = probeResult.snapshot
                    runtimeState.lastUpdatedAt = probeResult.snapshot.capturedAt
                case .failure(let message):
                    runtimeState.lastError = message
                }
            }

            runtimeStates[accountID] = runtimeState
        }

        updateState(save: false) { state in
            state.accounts = updatedAccounts
            if state.activeAccountID == nil {
                state.activeAccountID = state.accounts.first?.id
            }
        }
    }

    @discardableResult
    private func importCurrentAccountSync(setActive: Bool) throws -> AccountImportResult {
        log("Importing current account from ~/.codex/auth.json")
        let importedAccount = try store.importCurrentAccount(existingAccounts: state.accounts)
        let importResult = upsertImportedAccount(importedAccount, setActive: setActive)
        log("Imported account \(importResult.account.maskedEmail) with \(importResult.account.workspaces.count) workspace(s).")
        return importResult
    }

    private func saveState() throws {
        try store.saveState(state)
    }

    private func upsertImportedAccount(_ importedAccount: StoredAccount, setActive: Bool) -> AccountImportResult {
        let wasNew = !state.accounts.contains(where: { $0.id == importedAccount.id })

        updateState { state in
            if let existingIndex = state.accounts.firstIndex(where: { $0.id == importedAccount.id }) {
                state.accounts[existingIndex] = importedAccount
            } else {
                state.accounts.append(importedAccount)
                state.accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
            }

            if setActive {
                state.activeAccountID = importedAccount.id
            } else if state.activeAccountID == nil {
                state.activeAccountID = state.accounts.first?.id
            }
        }

        return AccountImportResult(account: importedAccount, wasNew: wasNew)
    }

    private func updateState(save: Bool = true, _ mutate: (inout PersistedAppState) -> Void) {
        var updatedState = state
        mutate(&updatedState)
        state = updatedState

        guard save else {
            return
        }

        do {
            try saveState()
        } catch {
            transientError = error.localizedDescription
            log("Saving state failed: \(error.localizedDescription)")
        }
    }

    private func startAutoRefreshLoop() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self else {
                    return
                }
                await self.refreshAll()
            }
        }
    }

    private func log(_ message: String) {
        logger.append(message)
        refreshDiagnosticsReport()
    }

    private func preferredWorkspaceID(existingSelectionID: String, available workspaces: [StoredWorkspace]) -> String {
        if workspaces.contains(where: { $0.id == existingSelectionID }) {
            return existingSelectionID
        }

        if let defaultWorkspace = workspaces.first(where: \.isDefault) {
            return defaultWorkspace.id
        }

        return workspaces.first?.id ?? existingSelectionID
    }

    private func refreshDiagnosticsReport() {
        diagnosticsReport = buildDiagnosticsReport()
    }

    private func buildDiagnosticsReport() -> String {
        var lines: [String] = [
            "Storage: \(storagePath)",
            "Log file: \(diagnosticsLogPath)",
            "Codex executable: \(codexExecutablePath ?? "unresolved")",
            "Imported accounts: \(state.accounts.count)"
        ]

        if let transientError, !transientError.isEmpty {
            lines.append("Transient error: \(transientError)")
        }

        for account in state.accounts {
            let runtimeState = runtimeState(for: account.id)
            let workspaceLabel = account.selectedWorkspace?.menuLabel ?? "Unknown workspace"
            let error = runtimeState.lastError ?? "none"
            lines.append("Account \(account.maskedEmail) [\(workspaceLabel)] error: \(error)")
        }

        let logContents = logger.readContents(maxCharacters: 12_000)
        if !logContents.isEmpty {
            lines.append("")
            lines.append("Recent log:")
            lines.append(logContents)
        }

        return lines.joined(separator: "\n")
    }
}

private struct RefreshJob: Sendable {
    let accountID: String
    let workspaceID: String
    let homeURL: URL
}

private struct RefreshOutcome: Sendable {
    enum Result: Sendable {
        case success(ProbeResult)
        case failure(String)
    }

    let accountID: String
    let workspaceID: String
    let result: Result
}

private struct AccountImportResult: Sendable {
    let account: StoredAccount
    let wasNew: Bool
}
