//
//  MenuBarViewModel.swift
//  multi-codex-limit-viewer
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ServiceManagement

@MainActor
final class MenuBarViewModel: ObservableObject {
    static let settingsWindowIdentifier = "multi-codex-limit-viewer.settings"

    @Published private(set) var state: PersistedAppState
    @Published private(set) var runtimeStates: [String: AccountRuntimeState]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAddingAccount = false
    @Published var transientError: String?
    @Published private(set) var codexExecutablePath: String?
    @Published private(set) var diagnosticsReport = ""
    @Published private(set) var launchAtLoginEnabled = false

    private let store: AuthSnapshotStore
    private let probe: CodexUsageProbe
    private let loginFlow: CodexLoginFlow
    private let resolver: CodexExecutableResolver
    private let logger: DiagnosticsLogStore
    private let codexWindowTitleReader: CodexWindowTitleReader
    private var autoRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountFlowID: UUID?

    init(
        store: AuthSnapshotStore? = nil,
        probe: CodexUsageProbe? = nil,
        loginFlow: CodexLoginFlow? = nil,
        resolver: CodexExecutableResolver? = nil,
        logger: DiagnosticsLogStore? = nil,
        codexWindowTitleReader: CodexWindowTitleReader? = nil
    ) {
        self.store = store ?? AuthSnapshotStore()
        self.probe = probe ?? CodexUsageProbe()
        self.loginFlow = loginFlow ?? CodexLoginFlow()
        self.resolver = resolver ?? CodexExecutableResolver()
        self.logger = logger ?? DiagnosticsLogStore(rootURL: self.store.rootURL)
        self.codexWindowTitleReader = codexWindowTitleReader ?? CodexWindowTitleReader()
        state = (try? self.store.loadState()) ?? .empty
        runtimeStates = [:]
        syncLaunchAtLoginStatus()
        self.logger.append("App launched. storage=\(self.store.rootURL.path)")
        refreshDiagnosticsReport()

        Task {
            await bootstrap()
        }
    }

    deinit {
        autoRefreshTask?.cancel()
        addAccountTask?.cancel()

        let loginFlow = self.loginFlow
        Task {
            await loginFlow.cancelActiveLogin()
        }
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

    var languagePreference: AppLanguage {
        state.preferredLanguage
    }

    var effectiveLanguage: AppLanguage {
        state.preferredLanguage.effectiveLanguage
    }

    var languageOptions: [AppLanguage] {
        AppLanguage.allCases
    }

    var autoRefreshInterval: AutoRefreshInterval {
        state.autoRefreshInterval
    }

    var autoRefreshIntervalOptions: [AutoRefreshInterval] {
        AutoRefreshInterval.allCases
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

    func addAccount() {
        let shouldRestartExistingFlow = isAddingAccount || addAccountTask != nil
        if shouldRestartExistingFlow {
            log("Restarting Add Account after an unfinished browser login flow.")
            addAccountTask?.cancel()
        }

        transientError = nil
        isAddingAccount = true
        let flowID = UUID()
        addAccountFlowID = flowID

        addAccountTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.finishAddAccountFlow(flowID)
            }

            if shouldRestartExistingFlow {
                await self.loginFlow.cancelActiveLogin()

                do {
                    try Task.checkCancellation()
                } catch {
                    return
                }
            }

            do {
                try await self.addAccountInBrowser()
            } catch is CancellationError {
                self.log("Add Account cancelled.")
            } catch {
                self.transientError = error.localizedDescription
                self.log("Add Account failed: \(error.localizedDescription)")
            }
        }
    }

    func importCurrentAccount() async {
        guard !isAddingAccount else {
            log("Import Current Account skipped because an add-account flow is already running.")
            return
        }

        transientError = nil
        isAddingAccount = true
        defer {
            isAddingAccount = false
        }

        do {
            let importResult = try importCurrentAccountSync(setActive: true)
            if importResult.wasNew {
                log("Imported current Codex account \(importResult.account.maskedEmail).")
            } else {
                log(
                    "Current Codex account \(importResult.account.maskedEmail) is already imported. accountID=\(importResult.account.id) listUnchanged=true"
                )
            }
            await refreshAll()
        } catch {
            transientError = error.localizedDescription
            log("Import Current Account failed: \(error.localizedDescription)")
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
                let homeURL = store.codexHomeURL(for: account)

                if account.workspaces.isEmpty {
                    let fallbackWorkspaceID = account.selectedWorkspaceID.isEmpty ? account.id : account.selectedWorkspaceID
                    return [
                        RefreshJob(
                            accountID: account.id,
                            workspaceID: fallbackWorkspaceID,
                            requestedWorkspaceID: nil,
                            homeURL: homeURL
                        )
                    ]
                }

                return account.workspaces.map { workspace in
                    RefreshJob(
                        accountID: account.id,
                        workspaceID: workspace.id,
                        requestedWorkspaceID: workspace.id,
                        homeURL: homeURL
                    )
                }
            }

            let logger = self.logger
            let probe = self.probe

            let outcomes = await withTaskGroup(of: RefreshOutcome.self) { group in
                for job in jobs {
                    group.addTask {
                        let scope = "account=\(job.accountID) workspace=\(job.requestedWorkspaceID ?? "default")"
                        do {
                            let result = try await probe.fetchSnapshot(
                                executableURL: codexExecutable,
                                codexHomeURL: job.homeURL,
                                workspaceID: job.requestedWorkspaceID,
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
            applyVisibleCodexWorkspaceTitleIfAvailable()
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

    func deleteAccount(_ accountID: String) {
        guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else {
            return
        }

        let account = state.accounts[accountIndex]
        let remainingAccounts = state.accounts.enumerated().compactMap { index, storedAccount in
            index == accountIndex ? nil : storedAccount
        }

        if state.activeAccountID == accountID, let replacementAccount = remainingAccounts.first {
            do {
                try store.activateAccount(replacementAccount)
            } catch {
                transientError = error.localizedDescription
                log("Remove account from app failed while switching active account: \(error.localizedDescription)")
                return
            }
        }

        do {
            try store.removeStoredAccount(account)
        } catch {
            transientError = error.localizedDescription
            log("Remove account from app failed while removing stored auth: \(error.localizedDescription)")
            return
        }

        runtimeStates.removeValue(forKey: accountID)

        updateState { state in
            state.accounts.removeAll { $0.id == accountID }

            if state.activeAccountID == accountID {
                state.activeAccountID = remainingAccounts.first?.id
            } else if state.activeAccountID == nil {
                state.activeAccountID = state.accounts.first?.id
            }
        }

        log("Removed account \(account.maskedEmail) from app storage.")
    }

    func moveAccount(_ accountID: String, toIndex requestedIndex: Int) {
        updateState { state in
            guard let currentIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                return
            }

            let targetIndex = max(0, min(requestedIndex, max(state.accounts.count - 1, 0)))
            guard currentIndex != targetIndex else {
                return
            }

            let account = state.accounts.remove(at: currentIndex)
            state.accounts.insert(account, at: targetIndex)
        }
    }

    func toggleShowEmails() {
        updateState { state in
            state.showEmails.toggle()
        }
    }

    func setLanguage(_ language: AppLanguage) {
        updateState { state in
            state.preferredLanguage = language
        }
    }

    func autoRefreshIntervalDisplayName(for interval: AutoRefreshInterval) -> String {
        interval.displayTitle(in: effectiveLanguage)
    }

    func setAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        guard state.autoRefreshInterval != interval else {
            return
        }

        updateState { state in
            state.autoRefreshInterval = interval
        }
        startAutoRefreshLoop()
        log("Auto-refresh interval set to \(interval.displayTitle(in: .english)).")
    }

    func setLaunchAtLogin(_ isEnabled: Bool) {
        transientError = nil

        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            syncLaunchAtLoginStatus()
            log("Start at Login updated. enabled=\(launchAtLoginEnabled)")
        } catch {
            syncLaunchAtLoginStatus()
            transientError = launchAtLoginErrorMessage(for: error)
            log("Updating Start at Login failed: \(error.localizedDescription)")
        }
    }

    func openSettingsWindow() {
        log("Opening settings window.")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringSettingsWindowToFront(attemptsRemaining: 6)
    }

    func displayedEmail(for account: StoredAccount) -> String {
        state.showEmails ? account.email : account.maskedEmail
    }

    func text(_ key: AppTextKey) -> String {
        state.preferredLanguage.text(for: key)
    }

    func languageDisplayName(for language: AppLanguage) -> String {
        language.displayTitle(in: effectiveLanguage)
    }

    func localizedPlanTitle(for plan: PlanBadge) -> String {
        switch plan {
        case .free:
            return text(.planFree)
        case .go:
            return text(.planGo)
        case .plus:
            return text(.planPlus)
        case .pro:
            return text(.planPro)
        case .team:
            return text(.planTeam)
        case .business:
            return text(.planBusiness)
        case .enterprise:
            return text(.planEnterprise)
        case .edu:
            return text(.planEdu)
        case .unknown:
            return text(.planUnknown)
        }
    }

    func workspaceKindTitle(for kind: WorkspaceKind) -> String {
        switch kind {
        case .personal:
            return text(.workspaceKindPersonal)
        case .team:
            return text(.workspaceKindTeam)
        }
    }

    func workspaceKindTitle(for account: StoredAccount, workspace: StoredWorkspace?) -> String {
        workspaceKindTitle(for: account.displayWorkspaceKind(for: workspace))
    }

    func organizationName(for account: StoredAccount, workspace: StoredWorkspace?) -> String? {
        account.organizationName(for: workspace)
    }

    func accountSubtitle(for account: StoredAccount) -> String? {
        account.organizationName(for: account.selectedWorkspace)
    }

    func workspaceMenuLabel(for workspace: StoredWorkspace) -> String? {
        workspace.organizationName
    }

    func updatedText(since date: Date?) -> String {
        guard let date else {
            return text(.waitingFirstRefresh)
        }

        let relativeText = relativeUpdateText(since: date)
        if effectiveLanguage.isChinese {
            return relativeText == "刚刚" ? "刚刚更新" : "\(relativeText)更新"
        }
        return "Updated \(relativeText)"
    }

    func resetsInText(until date: Date) -> String {
        let remaining = remainingText(until: date)
        if effectiveLanguage.isChinese {
            return "\(remaining)后重置"
        }
        return "Resets in \(remaining)"
    }

    func meterTitle(for meter: UsageMeter) -> String {
        switch meter.windowDurationMinutes {
        case 300:
            return text(.fiveHours)
        case 1_440:
            return text(.daily)
        case 10_080:
            return text(.weekly)
        default:
            return meter.title
        }
    }

    func meterSummaryLabel(for meter: UsageMeter) -> String {
        switch meter.windowDurationMinutes {
        case 300:
            return "5h"
        case 10_080:
            return text(.weekly)
        case 1_440:
            return text(.daily)
        case .some(let minutes) where minutes > 0:
            return meter.compactTitle
        default:
            return meterTitle(for: meter)
        }
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
                        let mergedWorkspaces = mergeWorkspaceDisplayTitles(
                            workspaces,
                            existingWorkspaces: updatedAccounts[accountIndex].workspaces
                        )
                        updatedAccounts[accountIndex].workspaces = mergedWorkspaces
                        updatedAccounts[accountIndex].selectedWorkspaceID = preferredWorkspaceID(
                            existingSelectionID: updatedAccounts[accountIndex].selectedWorkspaceID,
                            available: mergedWorkspaces
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

    private func finishAddAccountFlow(_ flowID: UUID) {
        guard addAccountFlowID == flowID else {
            return
        }

        isAddingAccount = false
        addAccountFlowID = nil
        addAccountTask = nil
    }

    private func addAccountInBrowser() async throws {
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
            log: { [logger] message in
                logger.append(message)
            }
        )

        let authURL = pendingLoginHomeURL.appendingPathComponent("auth.json")
        let importedAccount = try store.importAccount(
            from: authURL,
            existingAccounts: state.accounts
        )
        let alreadyImported = state.accounts.contains(where: { $0.id == importedAccount.id })
        let addAccountResult = upsertImportedAccount(importedAccount, setActive: !alreadyImported)

        if alreadyImported {
            log(
                "Add Account browser login returned an existing account \(addAccountResult.account.maskedEmail). accountID=\(addAccountResult.account.id) listUnchanged=true"
            )
            await refreshAll()
            transientError = addAccountAlreadyImportedMessage(for: addAccountResult.account)
            refreshDiagnosticsReport()
            return
        }

        log("Added browser account \(addAccountResult.account.maskedEmail).")
        await refreshAll()
    }

    private func upsertImportedAccount(_ importedAccount: StoredAccount, setActive: Bool) -> AccountImportResult {
        let wasNew = !state.accounts.contains(where: { $0.id == importedAccount.id })

        updateState { state in
            if let existingIndex = state.accounts.firstIndex(where: { $0.id == importedAccount.id }) {
                state.accounts[existingIndex] = importedAccount
            } else {
                state.accounts.append(importedAccount)
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
        let interval = state.autoRefreshInterval.timeInterval
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }

                guard let self else {
                    return
                }
                await self.refreshAll()
            }
        }
    }

    private func syncLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            launchAtLoginEnabled = true
        case .notFound, .notRegistered:
            launchAtLoginEnabled = false
        @unknown default:
            launchAtLoginEnabled = false
        }
    }

    private func bringSettingsWindowToFront(attemptsRemaining: Int) {
        if let settingsWindow = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == Self.settingsWindowIdentifier
        }) {
            var behavior = settingsWindow.collectionBehavior
            behavior.insert(.moveToActiveSpace)
            settingsWindow.collectionBehavior = behavior
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            log("Settings window brought to front.")
            return
        }

        guard attemptsRemaining > 0 else {
            log("Settings window fronting skipped because the window could not be found.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.bringSettingsWindowToFront(attemptsRemaining: attemptsRemaining - 1)
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

    private func applyVisibleCodexWorkspaceTitleIfAvailable() {
        guard
            let currentAccountID = try? store.currentAccountID(),
            let rawWindowTitle = codexWindowTitleReader.currentVisibleWindowTitle(),
            let displayTitleOverride = normalizedCodexWorkspaceTitle(from: rawWindowTitle),
            let accountIndex = state.accounts.firstIndex(where: { $0.id == currentAccountID })
        else {
            return
        }

        let account = state.accounts[accountIndex]
        guard
            let workspaceIndex = account.workspaces.firstIndex(where: { $0.id == account.selectedWorkspaceID })
                ?? account.workspaces.indices.first
        else {
            return
        }

        if account.workspaces[workspaceIndex].trimmedDisplayTitleOverride == displayTitleOverride {
            return
        }

        updateState(save: false) { state in
            guard let accountIndex = state.accounts.firstIndex(where: { $0.id == currentAccountID }) else {
                return
            }

            let selectedWorkspaceID = state.accounts[accountIndex].selectedWorkspaceID
            guard
                let workspaceIndex = state.accounts[accountIndex].workspaces.firstIndex(where: { $0.id == selectedWorkspaceID })
                    ?? state.accounts[accountIndex].workspaces.indices.first
            else {
                return
            }

            state.accounts[accountIndex].workspaces[workspaceIndex].displayTitleOverride = displayTitleOverride
        }

        log("Observed Codex window title for account \(account.maskedEmail): \(displayTitleOverride)")
    }

    private func normalizedCodexWorkspaceTitle(from rawWindowTitle: String) -> String? {
        var title = rawWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        for suffix in [" - Codex", " | Codex", " · Codex", " — Codex"] {
            if let range = title.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !title.isEmpty else {
            return nil
        }

        let ignoredTitles = ["Codex", "ChatGPT", "OpenAI Codex"]
        guard !ignoredTitles.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) else {
            return nil
        }

        return title
    }

    private func refreshDiagnosticsReport() {
        diagnosticsReport = buildDiagnosticsReport()
    }

    private func addAccountAlreadyImportedMessage(for account: StoredAccount) -> String {
        if effectiveLanguage.isChinese {
            return "浏览器登录回来的还是 \(account.maskedEmail)，它已经在列表里了，所以没有新增条目。想添加别的账号，请先在浏览器里切到那个账号后再登录。"
        }

        return "The browser signed back into \(account.maskedEmail), which is already in the list, so no new account was added. To add a different account, switch the browser to that account first and sign in again."
    }

    private func relativeUpdateText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))

        if seconds < 60 {
            return effectiveLanguage.isChinese ? "刚刚" : "just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            if effectiveLanguage.isChinese {
                return "\(minutes) 分钟前"
            }
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            if effectiveLanguage.isChinese {
                return "\(hours) 小时前"
            }
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }

        let days = hours / 24
        if effectiveLanguage.isChinese {
            return "\(days) 天前"
        }
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    private func remainingText(until date: Date) -> String {
        let remaining = max(0, date.timeIntervalSinceNow)
        let hours = Int(remaining) / 3_600
        let minutes = (Int(remaining) % 3_600) / 60
        let days = Int(remaining) / 86_400

        if days >= 2 {
            return effectiveLanguage.isChinese ? "\(days)天" : "\(days)d"
        }

        if hours > 0 {
            if effectiveLanguage.isChinese {
                return "\(hours)小时 \(minutes)分钟"
            }
            return "\(hours)h \(minutes)m"
        }

        let safeMinutes = max(minutes, 1)
        return effectiveLanguage.isChinese ? "\(safeMinutes)分钟" : "\(safeMinutes)m"
    }

    private func buildDiagnosticsReport() -> String {
        var lines: [String] = [
            "Storage: \(storagePath)",
            "Log file: \(diagnosticsLogPath)",
            "Codex executable: \(codexExecutablePath ?? "unresolved")",
            "Imported accounts: \(state.accounts.count)",
            "Start at Login: \(launchAtLoginEnabled ? "enabled" : "disabled")",
            "Auto refresh interval: \(state.autoRefreshInterval.displayTitle(in: .english))"
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

    private func launchAtLoginErrorMessage(for error: Error) -> String {
        if effectiveLanguage.isChinese {
            return "无法更新登录时启动：\(error.localizedDescription)"
        }
        return "Couldn't update Start at Login: \(error.localizedDescription)"
    }
}

struct CodexWindowTitleReader: Sendable {
    nonisolated func currentVisibleWindowTitle() -> String? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

        return (windows.first { window in
            (window[kCGWindowOwnerName as String] as? String) == "Codex"
                && !((window[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        })
        .flatMap { $0[kCGWindowName as String] as? String }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct RefreshJob: Sendable {
    let accountID: String
    let workspaceID: String
    let requestedWorkspaceID: String?
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
