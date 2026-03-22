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
    var kind: WorkspaceKind
    var role: String?
    var isDefault: Bool

    nonisolated var menuLabel: String {
        if trimmedTitle.isEmpty {
            return kind.displayTitle
        }
        return trimmedTitle
    }

    nonisolated var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated var isPersonalNamed: Bool {
        trimmedTitle.caseInsensitiveCompare("Personal") == .orderedSame
    }

    nonisolated var displayName: String {
        isPersonalNamed ? "personal" : menuLabel
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

    var selectedWorkspace: StoredWorkspace? {
        workspaces.first(where: { $0.id == selectedWorkspaceID }) ?? workspaces.first
    }

    var preferredOrganizationWorkspace: StoredWorkspace? {
        workspaces.first(where: { !$0.isPersonalNamed }) ?? workspaces.first(where: { $0.kind == .team })
    }

    func organizationDisplayName(for workspace: StoredWorkspace?) -> String {
        if let workspace, !workspace.isPersonalNamed {
            return workspace.displayName
        }

        if let preferredOrganizationWorkspace {
            return preferredOrganizationWorkspace.displayName
        }

        if plan.isOrganizationPlan {
            return "\(plan.title) Plan"
        }

        return workspace?.displayName ?? "personal"
    }

    var currentOrganizationDisplayName: String {
        organizationDisplayName(for: selectedWorkspace)
    }
}

struct PersistedAppState: Codable, Sendable {
    var activeAccountID: String?
    var showEmails: Bool
    var accounts: [StoredAccount]

    static let empty = PersistedAppState(activeAccountID: nil, showEmails: false, accounts: [])
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
