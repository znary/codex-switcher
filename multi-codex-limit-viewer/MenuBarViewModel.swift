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
    @Published private(set) var cloudSyncStatus: CloudSyncStatus

    private var store: AuthSnapshotStore
    private let probe: CodexUsageProbe
    private let loginFlow: CodexLoginFlow
    private let resolver: CodexExecutableResolver
    private let logger: DiagnosticsLogStore
    private let codexWindowTitleReader: CodexWindowTitleReader
    private var autoRefreshTask: Task<Void, Never>?
    private var addAccountTask: Task<Void, Never>?
    private var addAccountFlowID: UUID?
    private var workspaceWillSleepObserver: NSObjectProtocol?
    private var workspaceDidWakeObserver: NSObjectProtocol?

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
        self.logger = logger ?? DiagnosticsLogStore(rootURL: self.store.localRootURL)
        self.codexWindowTitleReader = codexWindowTitleReader ?? CodexWindowTitleReader()
        state = (try? self.store.loadState()) ?? .empty
        runtimeStates = [:]
        cloudSyncStatus = self.store.cloudSyncStatus()
        applyAppearance()
        syncLaunchAtLoginStatus()
        self.logger.append(
            "App launched. storage=\(self.store.rootURL.path) iCloud=\(self.store.iCloudRootURL?.path ?? "unavailable")"
        )
        observeWorkspacePowerEvents()
        refreshDiagnosticsReport()

        Task {
            await bootstrap()
        }
    }

    deinit {
        autoRefreshTask?.cancel()
        addAccountTask?.cancel()

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        if let workspaceWillSleepObserver {
            workspaceNotificationCenter.removeObserver(workspaceWillSleepObserver)
        }
        if let workspaceDidWakeObserver {
            workspaceNotificationCenter.removeObserver(workspaceDidWakeObserver)
        }

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

    var cloudStoragePath: String {
        cloudSyncStatus.iCloudStoragePath ?? unavailableValue()
    }

    var cloudSyncStatusTitle: String {
        switch cloudSyncStatus.phase {
        case .synced:
            return effectiveLanguage.isChinese ? "已一致" : "Matched"
        case .syncing:
            return effectiveLanguage.isChinese ? "同步中" : "Syncing"
        case .different:
            if localLooksNewerThanCloud {
                return effectiveLanguage.isChinese ? "本地有新内容" : "Local Changed"
            }
            if cloudLooksNewerThanLocal {
                return effectiveLanguage.isChinese ? "iCloud 有新内容" : "iCloud Changed"
            }
            return effectiveLanguage.isChinese ? "有差异" : "Different"
        case .localOnly:
            return effectiveLanguage.isChinese ? "只有本地" : "Local Only"
        case .iCloudOnly:
            return effectiveLanguage.isChinese ? "只有 iCloud" : "iCloud Only"
        case .unavailable:
            return effectiveLanguage.isChinese ? "不可用" : "Unavailable"
        case .empty:
            return effectiveLanguage.isChinese ? "暂无数据" : "No Data"
        }
    }

    var cloudSyncLastSyncText: String {
        guard let date = cloudSyncStatus.lastConfirmedSyncAt else {
            return effectiveLanguage.isChinese ? "还没有同步记录" : "No sync record yet"
        }

        let timestamp = formattedTimestamp(date)
        let relative = relativeUpdateText(since: date)
        if effectiveLanguage.isChinese {
            return "\(timestamp)（\(relative)）"
        }
        return "\(timestamp) (\(relative))"
    }

    var cloudSyncTrackedFilesText: String {
        "\(cloudSyncStatus.syncedItemCount)/\(cloudSyncStatus.trackedItemCount)"
    }

    var cloudSyncSummaryText: String {
        switch cloudSyncStatus.phase {
        case .synced:
            if effectiveLanguage.isChinese {
                return "本地和 iCloud 当前一致。"
            }
            return "Local and iCloud match right now."
        case .syncing:
            if effectiveLanguage.isChinese {
                return "iCloud 还在传文件，状态可能会晚一点更新。"
            }
            return "iCloud is still transferring files, so the status may update a bit later."
        case .different:
            if effectiveLanguage.isChinese {
                if localLooksNewerThanCloud {
                    return "这通常是这台 Mac 更新了本地数据，但你还没有把它手动写回 iCloud。只用一台设备时，也会出现这种情况。"
                }
                if cloudLooksNewerThanLocal {
                    return "iCloud 里有比本地更新的内容。本地已有数据，所以应用不会自动覆盖，请手动选择是否拉下来。"
                }
                return "本地和 iCloud 内容不一样。因为本地已经有数据，应用不会自动覆盖，请手动选同步方向。"
            }
            if localLooksNewerThanCloud {
                return "This usually means this Mac updated local data, but you have not pushed it back to iCloud yet. This can happen even when you only use one Mac."
            }
            if cloudLooksNewerThanLocal {
                return "iCloud has newer content than the local copy. Because local data already exists, the app will not overwrite it automatically. Pull it down manually if you want it."
            }
            return "Local and iCloud differ. Because local data already exists, the app will not overwrite it automatically. Pick a sync direction manually."
        case .localOnly:
            if effectiveLanguage.isChinese {
                return "当前只有本地有这批数据。需要时可以手动上传到 iCloud。"
            }
            return "Only the local copy exists right now. Upload to iCloud manually if you need it there."
        case .iCloudOnly:
            if effectiveLanguage.isChinese {
                return "当前只有 iCloud 有这批数据。本地缺文件时会自动补齐。"
            }
            return "Only the iCloud copy exists right now. Missing local files can be filled from iCloud automatically."
        case .unavailable:
            if effectiveLanguage.isChinese {
                return "这台 Mac 现在访问不到 iCloud Drive。"
            }
            return "This Mac cannot reach iCloud Drive right now."
        case .empty:
            if effectiveLanguage.isChinese {
                return "本地和 iCloud 还没有可同步的数据。"
            }
            return "Neither local storage nor iCloud has syncable data yet."
        }
    }

    var cloudSyncPolicyHintText: String {
        if effectiveLanguage.isChinese {
            return "所有持久化文件都按同一条规则处理：本地已有文件时不会自动覆盖，只在本地缺文件时从 iCloud 补齐。要改另一侧的数据，请手动选择覆盖方向。"
        }
        return "All persistent files follow the same rule: existing local files are never overwritten automatically, and iCloud only fills files that are missing locally. Use the manual overwrite buttons when you want to change the other side."
    }

    var canOverwriteLocalFromICloud: Bool {
        cloudSyncStatus.isICloudAvailable
            && !isRefreshing
            && !isAddingAccount
    }

    var canOverwriteICloudFromLocal: Bool {
        cloudSyncStatus.isICloudAvailable
            && !isRefreshing
            && !isAddingAccount
    }

    var canDeleteICloudStorage: Bool {
        cloudSyncStatus.isICloudAvailable
            && cloudSyncStatus.cloudItemCount > 0
            && !isRefreshing
            && !isAddingAccount
    }

    var languagePreference: AppLanguage {
        state.preferredLanguage
    }

    var preferredAppearance: AppAppearance {
        state.preferredAppearance
    }

    var effectiveLanguage: AppLanguage {
        state.preferredLanguage.effectiveLanguage
    }

    var languageOptions: [AppLanguage] {
        AppLanguage.allCases
    }

    var appearanceOptions: [AppAppearance] {
        AppAppearance.allCases
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

        defer {
            isRefreshing = false
            refreshDiagnosticsReport()
        }

        for account in state.accounts {
            var runtimeState = runtimeStates[account.id] ?? AccountRuntimeState()
            runtimeState.isLoading = true
            runtimeStates[account.id] = runtimeState
        }

        do {
            let codexExecutable = try resolver.resolve(log: logger.append)
            codexExecutablePath = codexExecutable.path
            log("Using codex executable: \(codexExecutable.path)")

            for account in state.accounts {
                store.prepareStoredAccountForUse(account)
            }

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
            do {
                try saveState()
            } catch {
                transientError = error.localizedDescription
                log("Saving refreshed local state failed: \(error.localizedDescription)")
            }
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

        syncAvailabilityTagFromRuntimeState(for: accountID)
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

    func visibleTags(for account: StoredAccount) -> [AccountTag] {
        account.visibleTags
    }

    func canAddCustomTag(to account: StoredAccount) -> Bool {
        account.customTags.count < AccountTag.maxCustomCount
    }

    func promptAddTag(to accountID: String) {
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        guard canAddCustomTag(to: account) else {
            transientError = customTagLimitReachedMessage()
            return
        }

        transientError = nil

        guard let rawTitle = promptForTagInput(
            promptTitle: addTagPromptTitle(for: account),
            promptMessage: tagPromptMessage(),
            placeholder: addTagPlaceholder(),
            initialValue: "",
            confirmTitle: addTagConfirmTitle(),
            validationMessage: { [self] rawTitle in
                customTagValidationMessage(rawTitle, in: account)
            }
        ) else {
            return
        }

        addCustomTag(rawTitle, to: accountID)
    }

    func promptEditTag(_ tag: AccountTag, from accountID: String) {
        guard tag.isCustom,
              let account = state.accounts.first(where: { $0.id == accountID }),
              account.tags.contains(where: { $0.id == tag.id }) else {
            return
        }

        transientError = nil

        guard let rawTitle = promptForTagInput(
            promptTitle: editTagPromptTitle(for: account),
            promptMessage: editTagPromptMessage(),
            placeholder: addTagPlaceholder(),
            initialValue: tag.title,
            confirmTitle: saveTagConfirmTitle(),
            validationMessage: { [self] rawTitle in
                customTagValidationMessage(rawTitle, in: account, excludingTagID: tag.id)
            }
        ) else {
            return
        }

        updateCustomTag(tag, with: rawTitle, in: accountID)
    }

    func removeTag(_ tag: AccountTag, from accountID: String) {
        guard tag.isCustom else {
            return
        }

        updateState { state in
            guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                return
            }

            state.accounts[accountIndex].tags.removeAll { $0.id == tag.id }
            state.accounts[accountIndex].tags = StoredAccount.normalizedTags(state.accounts[accountIndex].tags)
        }

        log("Removed tag \(tag.title) from account \(accountID).")
    }

    private func addCustomTag(_ rawTitle: String, to accountID: String) {
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        guard canAddCustomTag(to: account) else {
            transientError = customTagLimitReachedMessage()
            return
        }

        guard let tag = validatedCustomTag(rawTitle, in: account) else {
            return
        }

        transientError = nil

        updateState { state in
            guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                return
            }

            state.accounts[accountIndex].tags = StoredAccount.normalizedTags(
                state.accounts[accountIndex].tags + [tag]
            )
        }

        log("Added tag \(tag.title) to account \(accountID).")
    }

    private func updateCustomTag(_ tag: AccountTag, with rawTitle: String, in accountID: String) {
        guard tag.isCustom,
              let account = state.accounts.first(where: { $0.id == accountID }),
              let updatedTag = validatedCustomTag(rawTitle, in: account, excludingTagID: tag.id) else {
            return
        }

        transientError = nil

        updateState { state in
            guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }),
                  let tagIndex = state.accounts[accountIndex].tags.firstIndex(where: { $0.id == tag.id }) else {
                return
            }

            state.accounts[accountIndex].tags[tagIndex] = updatedTag
            state.accounts[accountIndex].tags = StoredAccount.normalizedTags(state.accounts[accountIndex].tags)
        }

        log("Updated tag \(tag.title) to \(updatedTag.title) on account \(accountID).")
    }

    private func validatedCustomTag(
        _ rawTitle: String,
        in account: StoredAccount,
        excludingTagID: String? = nil
    ) -> AccountTag? {
        if let validationMessage = customTagValidationMessage(
            rawTitle,
            in: account,
            excludingTagID: excludingTagID
        ) {
            transientError = validationMessage
            return nil
        }

        let normalizedTitle = AccountTag.normalizedTitle(from: rawTitle)
        guard let tag = AccountTag(title: normalizedTitle, kind: .custom) else {
            return nil
        }

        return tag
    }

    private func promptForTagInput(
        promptTitle: String,
        promptMessage: String,
        placeholder: String,
        initialValue: String,
        confirmTitle: String,
        validationMessage: @escaping (String) -> String?
    ) -> String? {
        let contentWidth: CGFloat = 320
        let accessoryHeight: CGFloat = 50
        let inputField = NSTextField(frame: NSRect(x: 0, y: 24, width: contentWidth, height: 24))
        inputField.placeholderString = placeholder
        inputField.stringValue = initialValue
        inputField.lineBreakMode = .byTruncatingTail

        let validationLabel = NSTextField(labelWithString: "")
        validationLabel.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 18)
        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .systemRed
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 0
        validationLabel.isHidden = true

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: accessoryHeight))
        accessoryView.addSubview(inputField)
        accessoryView.addSubview(validationLabel)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = promptTitle
        alert.informativeText = promptMessage
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelButtonTitle())

        guard let confirmButton = alert.buttons.first else {
            return nil
        }

        let updateValidationState: (Bool) -> Void = { showMessage in
            if let message = validationMessage(inputField.stringValue) {
                validationLabel.stringValue = showMessage ? message : ""
                validationLabel.isHidden = !showMessage
                confirmButton.isEnabled = false
            } else {
                validationLabel.stringValue = ""
                validationLabel.isHidden = true
                confirmButton.isEnabled = true
            }
        }

        let validationObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: inputField,
            queue: .main
        ) { _ in
            updateValidationState(true)
        }
        defer {
            NotificationCenter.default.removeObserver(validationObserver)
        }

        updateValidationState(false)

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return inputField.stringValue
    }

    private func customTagValidationMessage(
        _ rawTitle: String,
        in account: StoredAccount,
        excludingTagID: String? = nil
    ) -> String? {
        let normalizedTitle = AccountTag.normalizedTitle(from: rawTitle)
        guard !normalizedTitle.isEmpty else {
            return emptyTagMessage()
        }

        guard !AccountTag.exceedsTitleLengthLimit(normalizedTitle) else {
            return customTagTitleTooLongMessage()
        }

        guard let tag = AccountTag(title: normalizedTitle, kind: .custom) else {
            return emptyTagMessage()
        }

        let hasDuplicate = account.tags.contains { existingTag in
            existingTag.id == tag.id && existingTag.id != excludingTagID
        }
        guard !hasDuplicate else {
            return duplicateTagMessage(for: tag.title)
        }

        return nil
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

    func setAppearance(_ appearance: AppAppearance) {
        guard state.preferredAppearance != appearance else {
            return
        }

        updateState { state in
            state.preferredAppearance = appearance
        }
        applyAppearance()
        log("Appearance set to \(appearance.rawValue).")
    }

    func autoRefreshIntervalDisplayName(for interval: AutoRefreshInterval) -> String {
        interval.displayTitle(in: effectiveLanguage)
    }

    func appearanceDisplayName(for appearance: AppAppearance) -> String {
        appearance.displayTitle(in: effectiveLanguage)
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

    func refreshCloudSyncStatus() {
        cloudSyncStatus = store.cloudSyncStatus()
        refreshDiagnosticsReport()
    }

    func overwriteLocalDataFromICloud() {
        guard canOverwriteLocalFromICloud else {
            transientError = cloudSyncActionUnavailableMessage()
            return
        }

        guard confirmOverwriteLocalFromICloud() else {
            return
        }

        transientError = nil

        do {
            try store.overwriteLocalDataFromICloud()
            rebuildStoreState()
            runtimeStates = [:]
            syncActiveAccountToCodexHomeIfNeeded()
            log("Replaced local persistent data with the current iCloud copy.")

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.refreshAll()
            }
        } catch {
            transientError = error.localizedDescription
            log("Replacing local data from iCloud failed: \(error.localizedDescription)")
        }
    }

    func overwriteICloudDataFromLocal() {
        guard canOverwriteICloudFromLocal else {
            transientError = cloudSyncActionUnavailableMessage()
            return
        }

        guard confirmOverwriteICloudFromLocal() else {
            return
        }

        transientError = nil

        do {
            try store.overwriteICloudDataFromLocal()
            refreshCloudSyncStatus()
            log("Replaced the current iCloud copy with local persistent data.")
        } catch {
            transientError = error.localizedDescription
            log("Replacing iCloud data from local failed: \(error.localizedDescription)")
        }
    }

    func deleteICloudStorage() {
        guard canDeleteICloudStorage else {
            transientError = cloudSyncActionUnavailableMessage()
            return
        }

        guard confirmDeleteICloudStorage() else {
            return
        }

        transientError = nil

        do {
            try store.deleteICloudStorage()
            refreshCloudSyncStatus()
            log("Deleted the current iCloud persistent data.")
        } catch {
            transientError = error.localizedDescription
            log("Deleting iCloud data failed: \(error.localizedDescription)")
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
                    runtimeState.errorsByWorkspaceID.removeValue(forKey: outcome.workspaceID)
                    runtimeState.lastUpdatedAt = probeResult.snapshot.capturedAt
                case .failure(let message):
                    runtimeState.errorsByWorkspaceID[outcome.workspaceID] = message
                }
            }

            let selectedWorkspaceFailure = selectedWorkspaceFailureMessage(
                for: updatedAccounts[accountIndex],
                runtimeState: runtimeState
            )
            runtimeState.lastError = selectedWorkspaceFailure
            syncAvailabilityTag(for: &updatedAccounts[accountIndex], failureMessage: selectedWorkspaceFailure)

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
        refreshCloudSyncStatus()
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

    private func applyAppearance() {
        NSApplication.shared.appearance = state.preferredAppearance.nsAppearance
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

    private func observeWorkspacePowerEvents() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceWillSleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log("System will sleep.")
        }

        workspaceDidWakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.log("System did wake. Restarting auto-refresh loop and refreshing immediately.")
            self.startAutoRefreshLoop()

            Task { @MainActor [weak self] in
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

    private func syncAvailabilityTag(
        for account: inout StoredAccount,
        failureMessage: String?
    ) {
        account.tags.removeAll { $0.kind == .availability }

        guard let failureMessage else {
            account.tags = StoredAccount.normalizedTags(account.tags)
            return
        }

        guard let availabilityTag = AccountTag(
            title: availabilityTagTitle(for: failureMessage),
            kind: .availability
        ) else {
            account.tags = StoredAccount.normalizedTags(account.tags)
            return
        }

        account.tags = StoredAccount.normalizedTags(account.tags + [availabilityTag])
    }

    private func syncAvailabilityTagFromRuntimeState(for accountID: String) {
        guard let account = state.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        let runtimeState = runtimeStates[accountID] ?? AccountRuntimeState()
        let failureMessage = selectedWorkspaceFailureMessage(for: account, runtimeState: runtimeState)

        updateState { state in
            guard let accountIndex = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                return
            }

            syncAvailabilityTag(for: &state.accounts[accountIndex], failureMessage: failureMessage)
        }

        if runtimeStates[accountID] != nil {
            runtimeStates[accountID]?.lastError = failureMessage
        }
    }

    private func selectedWorkspaceFailureMessage(
        for account: StoredAccount,
        runtimeState: AccountRuntimeState
    ) -> String? {
        let workspaceID = selectedWorkspaceID(for: account)

        if let failureMessage = runtimeState.errorsByWorkspaceID[workspaceID] {
            return failureMessage
        }

        if runtimeState.snapshotsByWorkspaceID[workspaceID] != nil {
            return nil
        }

        return nil
    }

    private func selectedWorkspaceID(for account: StoredAccount) -> String {
        if !account.selectedWorkspaceID.isEmpty {
            return account.selectedWorkspaceID
        }

        if let firstWorkspaceID = account.workspaces.first?.id, !firstWorkspaceID.isEmpty {
            return firstWorkspaceID
        }

        return account.id
    }

    private func availabilityTagTitle(for message: String) -> String {
        let normalizedMessage = message.lowercased()

        if normalizedMessage.contains("401")
            || normalizedMessage.contains("403")
            || normalizedMessage.contains("unauthorized")
            || normalizedMessage.contains("forbidden")
            || normalizedMessage.contains("login")
            || normalizedMessage.contains("auth") {
            return effectiveLanguage.isChinese ? "登录失效" : "Login Expired"
        }

        if normalizedMessage.contains("timed out")
            || normalizedMessage.contains("timeout") {
            return effectiveLanguage.isChinese ? "请求超时" : "Timed Out"
        }

        if normalizedMessage.contains("could not resolve the codex executable")
            || normalizedMessage.contains("codex executable")
            || normalizedMessage.contains("no such file")
            || normalizedMessage.contains("command not found") {
            return effectiveLanguage.isChinese ? "Codex 不可用" : "Codex Missing"
        }

        if normalizedMessage.contains("connection")
            || normalizedMessage.contains("closed")
            || normalizedMessage.contains("network")
            || normalizedMessage.contains("econn") {
            return effectiveLanguage.isChinese ? "连接失败" : "Connection Failed"
        }

        return effectiveLanguage.isChinese ? "不可用" : "Unavailable"
    }

    private func addTagPromptTitle(for account: StoredAccount) -> String {
        if effectiveLanguage.isChinese {
            return "给 \(displayedEmail(for: account)) 添加标签"
        }
        return "Add a tag to \(displayedEmail(for: account))"
    }

    private func tagPromptMessage() -> String {
        if effectiveLanguage.isChinese {
            return "最多可以添加 \(AccountTag.maxCustomCount) 个自定义标签，每个标签最多 \(AccountTag.maxTitleLength) 个字符。"
        }
        return "You can add up to \(AccountTag.maxCustomCount) custom tags, and each tag can have up to \(AccountTag.maxTitleLength) characters."
    }

    private func editTagPromptTitle(for account: StoredAccount) -> String {
        if effectiveLanguage.isChinese {
            return "编辑 \(displayedEmail(for: account)) 的标签"
        }
        return "Edit a tag for \(displayedEmail(for: account))"
    }

    private func editTagPromptMessage() -> String {
        if effectiveLanguage.isChinese {
            return "每个标签最多 \(AccountTag.maxTitleLength) 个字符。"
        }
        return "Each tag can have up to \(AccountTag.maxTitleLength) characters."
    }

    private func addTagPlaceholder() -> String {
        effectiveLanguage.isChinese ? "输入标签名" : "Enter a tag"
    }

    private func addTagConfirmTitle() -> String {
        effectiveLanguage.isChinese ? "添加" : "Add"
    }

    private func saveTagConfirmTitle() -> String {
        effectiveLanguage.isChinese ? "保存" : "Save"
    }

    private func cancelButtonTitle() -> String {
        effectiveLanguage.isChinese ? "取消" : "Cancel"
    }

    private func customTagLimitReachedMessage() -> String {
        if effectiveLanguage.isChinese {
            return "每个账号最多只能添加 \(AccountTag.maxCustomCount) 个自定义标签。"
        }
        return "Each account can have up to \(AccountTag.maxCustomCount) custom tags."
    }

    private func customTagTitleTooLongMessage() -> String {
        if effectiveLanguage.isChinese {
            return "每个标签最多只能输入 \(AccountTag.maxTitleLength) 个字符。"
        }
        return "Each tag can have up to \(AccountTag.maxTitleLength) characters."
    }

    private func emptyTagMessage() -> String {
        effectiveLanguage.isChinese ? "标签名不能为空。" : "Tag name can't be empty."
    }

    private func duplicateTagMessage(for title: String) -> String {
        if effectiveLanguage.isChinese {
            return "标签“\(title)”已经存在了。"
        }
        return "The tag “\(title)” already exists."
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
            "iCloud storage: \(cloudSyncStatus.iCloudStoragePath ?? "unavailable")",
            "Cloud sync: \(cloudSyncStatus.phase.rawValue)",
            "Cloud sync items: \(cloudSyncStatus.syncedItemCount)/\(cloudSyncStatus.trackedItemCount)",
            "Local items: \(cloudSyncStatus.localItemCount)",
            "Cloud items: \(cloudSyncStatus.cloudItemCount)",
            "Cloud sync last action: \(cloudSyncStatus.lastConfirmedSyncAt?.description ?? "none")",
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

    private func rebuildStoreState() {
        store = AuthSnapshotStore()
        state = (try? store.loadState()) ?? .empty
        cloudSyncStatus = store.cloudSyncStatus()
        refreshDiagnosticsReport()
    }

    private func formattedTimestamp(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func unavailableValue() -> String {
        effectiveLanguage.isChinese ? "不可用" : "Unavailable"
    }

    private var localLooksNewerThanCloud: Bool {
        guard cloudSyncStatus.phase == .different else {
            return false
        }
        guard let lastLocalChangeAt = cloudSyncStatus.lastLocalChangeAt else {
            return false
        }
        let lastCloudChangeAt = cloudSyncStatus.lastCloudChangeAt ?? .distantPast
        return lastLocalChangeAt > lastCloudChangeAt
    }

    private var cloudLooksNewerThanLocal: Bool {
        guard cloudSyncStatus.phase == .different else {
            return false
        }
        guard let lastCloudChangeAt = cloudSyncStatus.lastCloudChangeAt else {
            return false
        }
        let lastLocalChangeAt = cloudSyncStatus.lastLocalChangeAt ?? .distantPast
        return lastCloudChangeAt > lastLocalChangeAt
    }

    private func cloudSyncActionUnavailableMessage() -> String {
        if isRefreshing || isAddingAccount {
            if effectiveLanguage.isChinese {
                return "请等当前刷新或登录流程结束后再操作 iCloud 同步。"
            }
            return "Wait for the current refresh or login flow to finish before changing iCloud sync."
        }

        if effectiveLanguage.isChinese {
            return "这台 Mac 现在不能操作 iCloud 同步。"
        }
        return "iCloud sync cannot be changed on this Mac right now."
    }

    private func syncActiveAccountToCodexHomeIfNeeded() {
        guard let activeAccount else {
            return
        }

        do {
            try store.activateAccount(activeAccount)
        } catch {
            transientError = error.localizedDescription
            log("Activating the current account after reloading local storage failed: \(error.localizedDescription)")
        }
    }

    private func confirmOverwriteLocalFromICloud() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if effectiveLanguage.isChinese {
            alert.messageText = "用 iCloud 覆盖本地"
            if cloudSyncStatus.cloudItemCount == 0 {
                alert.informativeText = "iCloud 里现在没有这批存储数据。继续后，本地的 app-state 和账号 auth 快照会被清空。"
            } else {
                alert.informativeText = "会用 iCloud 里的 app-state 和账号 auth 快照覆盖本地同名数据，本地已有内容不会保留。"
            }
            alert.addButton(withTitle: "覆盖本地")
        } else {
            alert.messageText = "Overwrite Local with iCloud"
            if cloudSyncStatus.cloudItemCount == 0 {
                alert.informativeText = "iCloud does not currently have this set of stored data. Continuing will clear the local app-state and stored auth snapshots."
            } else {
                alert.informativeText = "This overwrites the local app-state and stored auth snapshots with the current iCloud copy. Existing local content will not be kept."
            }
            alert.addButton(withTitle: "Overwrite Local")
        }
        alert.addButton(withTitle: cancelButtonTitle())

        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmOverwriteICloudFromLocal() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if effectiveLanguage.isChinese {
            alert.messageText = "用本地覆盖 iCloud"
            if cloudSyncStatus.localItemCount == 0 {
                alert.informativeText = "本地现在没有这批存储数据。继续后，iCloud 里的 app-state 和账号 auth 快照会被清空。"
            } else {
                alert.informativeText = "会用本地的 app-state 和账号 auth 快照覆盖 iCloud 同名数据，云端已有内容不会保留。"
            }
            alert.addButton(withTitle: "覆盖 iCloud")
        } else {
            alert.messageText = "Overwrite iCloud with Local"
            if cloudSyncStatus.localItemCount == 0 {
                alert.informativeText = "Local storage does not currently have this set of stored data. Continuing will clear the iCloud app-state and stored auth snapshots."
            } else {
                alert.informativeText = "This overwrites the iCloud app-state and stored auth snapshots with the current local copy. Existing iCloud content will not be kept."
            }
            alert.addButton(withTitle: "Overwrite iCloud")
        }
        alert.addButton(withTitle: cancelButtonTitle())

        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmDeleteICloudStorage() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if effectiveLanguage.isChinese {
            alert.messageText = "删除 iCloud 数据"
            alert.informativeText = "会删掉 iCloud 里的 app-state 和账号 auth 快照。本机数据不会受影响，应用仍然继续用本地数据。"
            alert.addButton(withTitle: "删除")
        } else {
            alert.messageText = "Delete iCloud Data"
            alert.informativeText = "This removes the app-state and stored auth snapshots from iCloud. Local data stays unchanged and the app continues using the local copy."
            alert.addButton(withTitle: "Delete")
        }
        alert.addButton(withTitle: cancelButtonTitle())

        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func launchAtLoginErrorMessage(for error: Error) -> String {
        if effectiveLanguage.isChinese {
            return "无法更新登录时启动：\(error.localizedDescription)"
        }
        return "Couldn't update Start at Login: \(error.localizedDescription)"
    }
}

private extension AppAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
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
