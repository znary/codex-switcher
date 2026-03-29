//
//  CodexMonitorModels.swift
//  multi-codex-limit-viewer
//

import Foundation

enum UsageProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPTCodex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPTCodex:
            return "ChatGPT Codex"
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    nonisolated var effectiveLanguage: AppLanguage {
        self == .system ? Self.systemResolvedLanguage : self
    }

    nonisolated var displayTitle: String {
        displayTitle(in: effectiveLanguage)
    }

    nonisolated func displayTitle(in language: AppLanguage) -> String {
        let resolvedLanguage = language.effectiveLanguage
        if resolvedLanguage == .simplifiedChinese {
            switch self {
            case .system:
                return "跟随系统"
            case .english:
                return "英语"
            case .simplifiedChinese:
                return "简体中文"
            }
        } else {
            switch self {
            case .system:
                return "Follow System"
            case .english:
                return "English"
            case .simplifiedChinese:
                return "Simplified Chinese"
            }
        }
    }

    nonisolated static var systemResolvedLanguage: AppLanguage {
        let preferredIdentifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        let locale = Locale(identifier: preferredIdentifier)
        let languageCode = locale.language.languageCode?.identifier.lowercased()
            ?? preferredIdentifier.lowercased()
        return languageCode.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    nonisolated var isChinese: Bool {
        effectiveLanguage == .simplifiedChinese
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    nonisolated func displayTitle(in language: AppLanguage) -> String {
        let resolvedLanguage = language.effectiveLanguage
        if resolvedLanguage == .simplifiedChinese {
            switch self {
            case .system:
                return "跟随系统"
            case .light:
                return "浅色"
            case .dark:
                return "暗色"
            }
        }

        switch self {
        case .system:
            return "Follow System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}

enum AutoRefreshInterval: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case fortyFiveSeconds = 45
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let defaultValue: AutoRefreshInterval = .fortyFiveSeconds

    var id: Int { rawValue }

    nonisolated var timeInterval: TimeInterval {
        TimeInterval(rawValue)
    }

    nonisolated func displayTitle(in language: AppLanguage) -> String {
        if language.effectiveLanguage == .simplifiedChinese {
            switch self {
            case .fifteenSeconds:
                return "15 秒"
            case .thirtySeconds:
                return "30 秒"
            case .fortyFiveSeconds:
                return "45 秒"
            case .oneMinute:
                return "1 分钟"
            case .twoMinutes:
                return "2 分钟"
            case .fiveMinutes:
                return "5 分钟"
            }
        }

        switch self {
        case .fifteenSeconds:
            return "15 sec"
        case .thirtySeconds:
            return "30 sec"
        case .fortyFiveSeconds:
            return "45 sec"
        case .oneMinute:
            return "1 min"
        case .twoMinutes:
            return "2 min"
        case .fiveMinutes:
            return "5 min"
        }
    }
}

enum AppTextKey: String, Codable, CaseIterable, Sendable {
    case settings
    case general
    case accounts
    case addAccount
    case importCurrentAccount
    case deleteAccount
    case addTag
    case editTag
    case deleteTag
    case statusPage
    case usageDashboard
    case copyDiagnostics
    case openLog
    case showEmails
    case hideEmails
    case refresh
    case refreshing
    case refreshNow
    case startAtLogin
    case startAtLoginDescription
    case refreshInterval
    case chooseRefreshInterval
    case appearance
    case chooseAppAppearance
    case language
    case followSystem
    case english
    case simplifiedChinese
    case chooseAppLanguage
    case iCloudSync
    case iCloudSyncStatus
    case iCloudSyncLastSync
    case iCloudSyncTrackedFiles
    case iCloudSyncCloudStorage
    case iCloudSyncOverwriteLocal
    case iCloudSyncOverwriteICloud
    case iCloudSyncDeleteStorage
    case codexCLI
    case diagnostics
    case about
    case aboutDescription
    case revealLogInFinder
    case noDiagnosticsCollected
    case howToAddMoreAccounts
    case howToAddMoreAccountsLine1
    case howToAddMoreAccountsLine2
    case importedAccounts
    case storedAt
    case logFile
    case version
    case github
    case codexExecutableUnresolved
    case workspaceKindPersonal
    case workspaceKindTeam
    case organizationName
    case unknownWorkspace
    case capacity
    case capacityRemaining
    case capacityUsed
    case capacityShowUsed
    case capacityShowRemaining
    case capacitySummaryRemaining
    case capacitySummaryUsed
    case capacityLeft
    case capacityUsedSuffix
    case waitingFirstRefresh
    case noImportedAccount
    case quit
    case current
    case weekly
    case daily
    case fiveHours
    case usage
    case planFree
    case planGo
    case planPlus
    case planPro
    case planTeam
    case planBusiness
    case planEnterprise
    case planEdu
    case planUnknown
}

private enum AppTextCatalog {
    static let english: [AppTextKey: String] = [
        .settings: "Settings",
        .general: "General",
        .accounts: "Accounts",
        .addAccount: "Add Account",
        .importCurrentAccount: "Import Current Account",
        .deleteAccount: "Remove From List",
        .addTag: "Add Tag",
        .editTag: "Edit Tag",
        .deleteTag: "Remove Tag",
        .statusPage: "Status Page",
        .usageDashboard: "Usage Dashboard",
        .copyDiagnostics: "Copy Diagnostics",
        .openLog: "Open Log",
        .showEmails: "Show Emails",
        .hideEmails: "Hide Emails",
        .refresh: "Refresh",
        .refreshing: "Refreshing",
        .refreshNow: "Refresh Now",
        .startAtLogin: "Start at Login",
        .startAtLoginDescription: "Open the app automatically when you sign in on this Mac.",
        .refreshInterval: "Refresh Interval",
        .chooseRefreshInterval: "Choose how often the app refreshes usage in the background.",
        .appearance: "Appearance",
        .chooseAppAppearance: "Choose whether the app follows the system, light mode, or dark mode.",
        .language: "Language",
        .followSystem: "Follow System",
        .english: "English",
        .simplifiedChinese: "Simplified Chinese",
        .chooseAppLanguage: "Choose the app language.",
        .iCloudSync: "iCloud Sync",
        .iCloudSyncStatus: "Status",
        .iCloudSyncLastSync: "Last Sync Action",
        .iCloudSyncTrackedFiles: "Matched Items",
        .iCloudSyncCloudStorage: "iCloud Storage",
        .iCloudSyncOverwriteLocal: "iCloud Overwrite Local",
        .iCloudSyncOverwriteICloud: "Local Overwrite iCloud",
        .iCloudSyncDeleteStorage: "Delete iCloud Data",
        .codexCLI: "Codex CLI",
        .diagnostics: "Diagnostics",
        .about: "About",
        .aboutDescription: "Monitor multiple ChatGPT Codex accounts from your Mac menu bar.",
        .revealLogInFinder: "Reveal Log In Finder",
        .noDiagnosticsCollected: "No diagnostics collected yet.",
        .howToAddMoreAccounts: "How To Add More Accounts",
        .howToAddMoreAccountsLine1: "Use Import Current Account to snapshot the Codex account already logged in on this Mac.",
        .howToAddMoreAccountsLine2: "Use Add Account to open the Codex browser login flow and save another account into its own storage.",
        .importedAccounts: "Imported accounts",
        .storedAt: "Stored at",
        .logFile: "Log file",
        .version: "Version",
        .github: "GitHub",
        .codexExecutableUnresolved: "codex executable not resolved yet",
        .workspaceKindPersonal: "Personal",
        .workspaceKindTeam: "Team",
        .organizationName: "Organization",
        .unknownWorkspace: "Unknown workspace",
        .capacity: "Capacity",
        .capacityRemaining: "Remaining",
        .capacityUsed: "Used",
        .capacityShowUsed: "Show Used",
        .capacityShowRemaining: "Show Remaining",
        .capacitySummaryRemaining: "Default view shows the room you still have.",
        .capacitySummaryUsed: "Quickly compare which windows are burning faster.",
        .capacityLeft: "left",
        .capacityUsedSuffix: "used",
        .waitingFirstRefresh: "Waiting for first refresh",
        .noImportedAccount: "No imported ChatGPT Codex account was found yet.",
        .quit: "Quit",
        .current: "Current",
        .weekly: "Weekly",
        .daily: "Daily",
        .fiveHours: "5 Hours",
        .usage: "Usage",
        .planFree: "Free",
        .planGo: "Go",
        .planPlus: "Plus",
        .planPro: "Pro",
        .planTeam: "Team",
        .planBusiness: "Business",
        .planEnterprise: "Enterprise",
        .planEdu: "Edu",
        .planUnknown: "Unknown"
    ]

    static let simplifiedChinese: [AppTextKey: String] = [
        .settings: "设置",
        .general: "通用",
        .accounts: "账户",
        .addAccount: "添加账户",
        .importCurrentAccount: "导入当前账户",
        .deleteAccount: "从列表移除",
        .addTag: "添加标签",
        .editTag: "编辑标签",
        .deleteTag: "删除标签",
        .statusPage: "当前状态",
        .usageDashboard: "数据看板",
        .copyDiagnostics: "复制诊断信息",
        .openLog: "打开日志",
        .showEmails: "显示邮箱",
        .hideEmails: "隐藏邮箱",
        .refresh: "刷新",
        .refreshing: "刷新中",
        .refreshNow: "立即刷新",
        .startAtLogin: "登录时启动",
        .startAtLoginDescription: "在这台 Mac 登录后自动打开应用。",
        .refreshInterval: "刷新间隔",
        .chooseRefreshInterval: "选择后台自动刷新用量的频率。",
        .appearance: "外观",
        .chooseAppAppearance: "选择跟随系统、浅色或暗色外观。",
        .language: "语言",
        .followSystem: "跟随系统",
        .english: "英语",
        .simplifiedChinese: "简体中文",
        .chooseAppLanguage: "选择应用语言。",
        .iCloudSync: "iCloud 同步",
        .iCloudSyncStatus: "当前状态",
        .iCloudSyncLastSync: "最近同步时间",
        .iCloudSyncTrackedFiles: "一致项目",
        .iCloudSyncCloudStorage: "iCloud 存储",
        .iCloudSyncOverwriteLocal: "用 iCloud 覆盖本地",
        .iCloudSyncOverwriteICloud: "用本地覆盖 iCloud",
        .iCloudSyncDeleteStorage: "删除 iCloud 数据",
        .codexCLI: "Codex CLI",
        .diagnostics: "诊断",
        .about: "关于",
        .aboutDescription: "在 Mac 菜单栏里查看多个 ChatGPT Codex 账户的用量。",
        .revealLogInFinder: "在访达中显示日志",
        .noDiagnosticsCollected: "还没有诊断信息。",
        .howToAddMoreAccounts: "如何添加更多账户",
        .howToAddMoreAccountsLine1: "点“导入当前账户”会读取这台 Mac 上当前已登录的 Codex 账户。",
        .howToAddMoreAccountsLine2: "点“添加账户”会打开 Codex 的浏览器登录流程，并把另一个账户保存到独立存储里。",
        .importedAccounts: "已导入账户",
        .storedAt: "存储位置",
        .logFile: "日志文件",
        .version: "版本",
        .github: "GitHub",
        .codexExecutableUnresolved: "还没有解析出 codex 可执行文件",
        .workspaceKindPersonal: "个人",
        .workspaceKindTeam: "团队",
        .organizationName: "组织",
        .unknownWorkspace: "未知工作区",
        .capacity: "容量",
        .capacityRemaining: "剩余",
        .capacityUsed: "已用",
        .capacityShowUsed: "显示已用",
        .capacityShowRemaining: "显示剩余",
        .capacitySummaryRemaining: "默认视图显示你还剩多少可用空间。",
        .capacitySummaryUsed: "快速比较哪些窗口消耗得更快。",
        .capacityLeft: "剩余",
        .capacityUsedSuffix: "已用",
        .waitingFirstRefresh: "等待首次刷新",
        .noImportedAccount: "还没有找到已导入的 ChatGPT Codex 账户。",
        .quit: "退出",
        .current: "当前",
        .weekly: "每周",
        .daily: "每天",
        .fiveHours: "5 小时",
        .usage: "用量",
        .planFree: "免费",
        .planGo: "Go",
        .planPlus: "Plus",
        .planPro: "Pro",
        .planTeam: "Team",
        .planBusiness: "Business",
        .planEnterprise: "Enterprise",
        .planEdu: "Edu",
        .planUnknown: "未知"
    ]

    static func string(for key: AppTextKey, language: AppLanguage) -> String {
        let resolvedLanguage = language.effectiveLanguage
        if resolvedLanguage == .simplifiedChinese {
            return simplifiedChinese[key] ?? english[key] ?? key.rawValue
        }
        return english[key] ?? key.rawValue
    }
}

extension AppLanguage {
    func text(for key: AppTextKey) -> String {
        AppTextCatalog.string(for: key, language: self)
    }
}

enum WorkspaceKind: String, Codable, Hashable, Sendable {
    case personal
    case team

    nonisolated init(title: String) {
        self = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Personal") == .orderedSame ? .personal : .team
    }

    nonisolated var label: String {
        switch self {
        case .personal:
            return "PERSONAL"
        case .team:
            return "TEAM"
        }
    }

    nonisolated var displayTitle: String {
        switch self {
        case .personal:
            return "Personal"
        case .team:
            return "Team"
        }
    }
}

enum PlanBadge: String, Codable, CaseIterable, Hashable, Sendable {
    case free
    case go
    case plus
    case pro
    case team
    case business
    case enterprise
    case edu
    case unknown

    nonisolated init(rawPlan: String?) {
        self = PlanBadge(rawValue: rawPlan?.lowercased() ?? "") ?? .unknown
    }

    nonisolated var title: String {
        switch self {
        case .free:
            return "Free"
        case .go:
            return "Go"
        case .plus:
            return "Plus"
        case .pro:
            return "Pro"
        case .team:
            return "Team"
        case .business:
            return "Business"
        case .enterprise:
            return "Enterprise"
        case .edu:
            return "Edu"
        case .unknown:
            return "Unknown"
        }
    }

    nonisolated var isOrganizationPlan: Bool {
        switch self {
        case .team, .business, .enterprise, .edu:
            return true
        default:
            return false
        }
    }
}

struct StoredWorkspace: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var displayTitleOverride: String?
    var kind: WorkspaceKind
    var role: String?
    var isDefault: Bool

    nonisolated var menuLabel: String {
        organizationDisplayName
    }

    nonisolated var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var isPersonalNamed: Bool {
        kind == .personal || trimmedTitle.caseInsensitiveCompare("Personal") == .orderedSame
    }

    nonisolated var organizationName: String? {
        if let displayTitleOverride = trimmedDisplayTitleOverride,
           !Self.shouldHideOrganizationName(displayTitleOverride) {
            return displayTitleOverride
        }

        let normalizedTitle = trimmedTitle
        guard !Self.shouldHideOrganizationName(normalizedTitle) else {
            return nil
        }

        return normalizedTitle
    }

    nonisolated var workspaceKindLabel: String {
        kind.displayTitle
    }

    nonisolated var organizationDisplayName: String {
        organizationName ?? workspaceKindLabel
    }

    nonisolated var displayName: String {
        organizationDisplayName
    }

    nonisolated var trimmedDisplayTitleOverride: String? {
        guard let displayTitleOverride else {
            return nil
        }

        let normalizedTitle = displayTitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTitle.isEmpty ? nil : normalizedTitle
    }

    nonisolated private static func isPersonalDisplayTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedTitle.caseInsensitiveCompare("Personal") == .orderedSame
            || normalizedTitle == "个人"
    }

    nonisolated private static func shouldHideOrganizationName(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            return true
        }

        if isPersonalDisplayTitle(normalizedTitle)
            || normalizedTitle.caseInsensitiveCompare("Team") == .orderedSame
            || normalizedTitle == "团队" {
            return true
        }

        let looksLikeDomainSlug = normalizedTitle.contains(".")
            && !normalizedTitle.contains(" ")
            && !normalizedTitle.contains("/")
        return looksLikeDomainSlug
    }
}

enum AccountTagKind: String, Codable, Hashable, Sendable {
    case custom
    case availability
}

struct AccountTag: Codable, Hashable, Identifiable, Sendable {
    nonisolated static let maxCustomCount = 5
    nonisolated static let maxTitleLength = 10

    var title: String
    var kind: AccountTagKind

    nonisolated var id: String {
        "\(kind.rawValue):\(normalizedKey)"
    }

    nonisolated var isCustom: Bool {
        kind == .custom
    }

    nonisolated var normalizedKey: String {
        Self.normalizedTitle(from: title).lowercased()
    }

    init?(title: String, kind: AccountTagKind = .custom) {
        let normalizedTitle = Self.normalizedTitle(from: title)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        self.title = normalizedTitle
        self.kind = kind
    }

    nonisolated static func normalizedTitle(from rawTitle: String) -> String {
        rawTitle
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func exceedsTitleLengthLimit(_ rawTitle: String) -> Bool {
        normalizedTitle(from: rawTitle).count > maxTitleLength
    }
}

struct StoredAccount: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var provider: UsageProviderID
    var email: String
    var maskedEmail: String
    var plan: PlanBadge
    var authHomeFolderName: String
    var workspaces: [StoredWorkspace]
    var selectedWorkspaceID: String
    var importedAt: Date
    var lastKnownRefreshAt: Date?
    var tags: [AccountTag]

    init(
        id: String,
        provider: UsageProviderID,
        email: String,
        maskedEmail: String,
        plan: PlanBadge,
        authHomeFolderName: String,
        workspaces: [StoredWorkspace],
        selectedWorkspaceID: String,
        importedAt: Date,
        lastKnownRefreshAt: Date?,
        tags: [AccountTag] = []
    ) {
        self.id = id
        self.provider = provider
        self.email = email
        self.maskedEmail = maskedEmail
        self.plan = plan
        self.authHomeFolderName = authHomeFolderName
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.importedAt = importedAt
        self.lastKnownRefreshAt = lastKnownRefreshAt
        self.tags = Self.normalizedTags(tags)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case email
        case maskedEmail
        case plan
        case authHomeFolderName
        case workspaces
        case selectedWorkspaceID
        case importedAt
        case lastKnownRefreshAt
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(UsageProviderID.self, forKey: .provider)
        email = try container.decode(String.self, forKey: .email)
        maskedEmail = try container.decode(String.self, forKey: .maskedEmail)
        plan = try container.decode(PlanBadge.self, forKey: .plan)
        authHomeFolderName = try container.decode(String.self, forKey: .authHomeFolderName)
        workspaces = try container.decodeIfPresent([StoredWorkspace].self, forKey: .workspaces) ?? []
        selectedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .selectedWorkspaceID) ?? ""
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        lastKnownRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastKnownRefreshAt)
        tags = Self.normalizedTags(try container.decodeIfPresent([AccountTag].self, forKey: .tags) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(email, forKey: .email)
        try container.encode(maskedEmail, forKey: .maskedEmail)
        try container.encode(plan, forKey: .plan)
        try container.encode(authHomeFolderName, forKey: .authHomeFolderName)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(selectedWorkspaceID, forKey: .selectedWorkspaceID)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(lastKnownRefreshAt, forKey: .lastKnownRefreshAt)
        try container.encode(Self.normalizedTags(tags), forKey: .tags)
    }

    var selectedWorkspace: StoredWorkspace? {
        workspaces.first(where: { $0.id == selectedWorkspaceID }) ?? workspaces.first
    }

    var visibleTags: [AccountTag] {
        let availabilityTags = tags.filter { $0.kind == .availability }
        let customTags = tags.filter { $0.kind == .custom }
        return availabilityTags + Array(customTags.prefix(AccountTag.maxCustomCount))
    }

    var customTags: [AccountTag] {
        tags.filter { $0.kind == .custom }
    }

    var preferredOrganizationWorkspace: StoredWorkspace? {
        workspaces.first(where: { $0.kind == .team }) ?? workspaces.first
    }

    func organizationName(for workspace: StoredWorkspace?) -> String? {
        workspace?.organizationName
    }

    func displayWorkspaceKind(for workspace: StoredWorkspace?) -> WorkspaceKind {
        if let workspace, workspace.organizationName != nil || workspace.kind == .personal {
            return workspace.kind
        }

        if plan.isOrganizationPlan {
            return .team
        }

        return workspace?.kind ?? .personal
    }

    func organizationDisplayName(for workspace: StoredWorkspace?) -> String {
        organizationName(for: workspace) ?? displayWorkspaceKind(for: workspace).displayTitle
    }

    var currentOrganizationDisplayName: String {
        organizationDisplayName(for: selectedWorkspace)
    }

    var currentOrganizationName: String? {
        organizationName(for: selectedWorkspace)
    }

    nonisolated static func normalizedTags(_ tags: [AccountTag]) -> [AccountTag] {
        var uniqueTags: [AccountTag] = []
        var seenIDs = Set<String>()
        var customTagCount = 0

        let orderedTags = tags.filter { $0.kind == .availability } + tags.filter { $0.kind == .custom }

        for tag in orderedTags {
            guard seenIDs.insert(tag.id).inserted else {
                continue
            }

            if tag.kind == .custom {
                guard customTagCount < AccountTag.maxCustomCount else {
                    continue
                }
                customTagCount += 1
            }

            uniqueTags.append(tag)
        }

        return uniqueTags
    }
}

struct PersistedAppState: Codable, Sendable {
    var activeAccountID: String?
    var showEmails: Bool
    var preferredLanguage: AppLanguage
    var preferredAppearance: AppAppearance
    var autoRefreshInterval: AutoRefreshInterval
    var accounts: [StoredAccount]

    static let empty = PersistedAppState()

    init(
        activeAccountID: String? = nil,
        showEmails: Bool = false,
        preferredLanguage: AppLanguage = .system,
        preferredAppearance: AppAppearance = .system,
        autoRefreshInterval: AutoRefreshInterval = .defaultValue,
        accounts: [StoredAccount] = []
    ) {
        self.activeAccountID = activeAccountID
        self.showEmails = showEmails
        self.preferredLanguage = preferredLanguage
        self.preferredAppearance = preferredAppearance
        self.autoRefreshInterval = autoRefreshInterval
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case activeAccountID
        case showEmails
        case preferredLanguage
        case preferredAppearance
        case autoRefreshInterval
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeAccountID = try container.decodeIfPresent(String.self, forKey: .activeAccountID)
        showEmails = try container.decodeIfPresent(Bool.self, forKey: .showEmails) ?? false
        preferredLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .preferredLanguage) ?? .system
        preferredAppearance = try container.decodeIfPresent(AppAppearance.self, forKey: .preferredAppearance) ?? .system
        autoRefreshInterval = try container.decodeIfPresent(AutoRefreshInterval.self, forKey: .autoRefreshInterval) ?? .defaultValue
        accounts = try container.decodeIfPresent([StoredAccount].self, forKey: .accounts) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activeAccountID, forKey: .activeAccountID)
        try container.encode(showEmails, forKey: .showEmails)
        try container.encode(preferredLanguage, forKey: .preferredLanguage)
        try container.encode(preferredAppearance, forKey: .preferredAppearance)
        try container.encode(autoRefreshInterval, forKey: .autoRefreshInterval)
        try container.encode(accounts, forKey: .accounts)
    }
}

struct UsageMeter: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var usedPercent: Double
    var windowDurationMinutes: Int?
    var resetsAt: Date?

    var compactTitle: String {
        switch windowDurationMinutes {
        case 300:
            return "5h"
        case 1_440:
            return "1d"
        case 10_080:
            return "1w"
        case .some(let minutes) where minutes > 0:
            return "\(minutes)m"
        default:
            return title
        }
    }
}

struct UsageSnapshot: Hashable, Sendable {
    var capturedAt: Date
    var meters: [UsageMeter]
    var plan: PlanBadge
}

struct ProbeResult: Sendable {
    var email: String
    var plan: PlanBadge
    var workspaces: [StoredWorkspace]?
    var snapshot: UsageSnapshot
}

struct AccountRuntimeState {
    var snapshotsByWorkspaceID: [String: UsageSnapshot] = [:]
    var errorsByWorkspaceID: [String: String] = [:]
    var lastUpdatedAt: Date?
    var lastError: String?
    var isLoading = false
}

extension StoredAccount {
    func workspace(withID workspaceID: String?) -> StoredWorkspace? {
        guard let workspaceID else {
            return selectedWorkspace
        }
        return workspaces.first(where: { $0.id == workspaceID })
    }
}

func maskEmailAddress(_ email: String) -> String {
    let components = email.split(separator: "@", maxSplits: 1).map(String.init)
    guard components.count == 2, let firstCharacter = components[0].first else {
        return email
    }

    return "\(firstCharacter)...@\(components[1])"
}
