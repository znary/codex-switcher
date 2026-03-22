//
//  MenuBarViews.swift
//  multi-codex-limit-viewer
//

import AppKit
import SwiftUI

private enum CapacityDisplayMode: String {
    case remaining
    case used

    var title: String {
        switch self {
        case .remaining:
            return "Remaining"
        case .used:
            return "Used"
        }
    }

    var toggleTitle: String {
        switch self {
        case .remaining:
            return "Show Used"
        case .used:
            return "Show Remaining"
        }
    }

    var summaryText: String {
        switch self {
        case .remaining:
            return "Default view shows the room you still have."
        case .used:
            return "Quickly compare which windows are burning faster."
        }
    }

    func percent(for meter: UsageMeter) -> Int {
        let used = max(0, min(meter.usedPercent, 100))

        switch self {
        case .remaining:
            return Int((100 - used).rounded())
        case .used:
            return Int(used.rounded())
        }
    }

    func progress(for meter: UsageMeter) -> Double {
        Double(percent(for: meter)) / 100
    }

    func detailLabel(for meter: UsageMeter) -> String {
        switch self {
        case .remaining:
            return percent(for: meter) == 1 ? "left" : "left"
        case .used:
            return "used"
        }
    }
}

struct MenuBarRootView: View {
    @AppStorage("capacityDisplayMode") private var capacityDisplayModeRawValue = CapacityDisplayMode.remaining.rawValue
    @ObservedObject var viewModel: MenuBarViewModel

    private var capacityDisplayMode: CapacityDisplayMode {
        CapacityDisplayMode(rawValue: capacityDisplayModeRawValue) ?? .remaining
    }

    var body: some View {
        Group {
            if let activeAccount = viewModel.activeAccount,
               let activeWorkspace = viewModel.activeWorkspace {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header(account: activeAccount, workspace: activeWorkspace)
                        usageSection(account: activeAccount)
                        accountsSection
                        footerActions
                    }
                    .padding(18)
                }
                .background(ScrollChromeTuner())
                .frame(width: 388, height: 700)
            } else {
                emptyState
                    .frame(width: 388, height: 300)
            }
        }
        .background(
            LinearGradient(
                colors: [Color.codexCanvas, Color.codexCanvasShadow],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func header(account: StoredAccount, workspace: StoredWorkspace) -> some View {
        MenuSectionCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.codexInk)

                    Text(updatedText(for: account.id))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.codexSecondary)

                    if let error = viewModel.runtimeState(for: account.id).lastError {
                        diagnosticsErrorBlock(error)
                    } else if let transientError = viewModel.transientError {
                        diagnosticsErrorBlock(transientError)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 12) {
                    Text(viewModel.displayedEmail(for: account))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.codexInk)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)

                    if account.workspaces.count > 1 {
                        WorkspacePicker(
                            account: account,
                            selectedWorkspace: workspace,
                            labelTitle: account.organizationDisplayName(for: workspace),
                            onSelect: { workspaceID in
                                viewModel.selectWorkspace(workspaceID, for: account.id)
                            }
                        )
                    } else {
                        WorkspaceBadge(
                            title: account.currentOrganizationDisplayName,
                            icon: account.plan.isOrganizationPlan ? "building.2.crop.circle" : "person.crop.circle"
                        )
                    }

                    Button {
                        Task {
                            await viewModel.refreshAll()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                            }

                            Text(viewModel.isRefreshing ? "Refreshing" : "Refresh")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.codexInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.codexCardRaised)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.codexStroke, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRefreshing)
                }
            }
        }
    }

    private func usageSection(account: StoredAccount) -> some View {
        MenuSectionCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Capacity")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.codexInk)

                    Text(capacityDisplayMode.summaryText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.codexSecondary)
                }

                Spacer(minLength: 0)

                Button {
                    capacityDisplayModeRawValue = nextCapacityDisplayMode.rawValue
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right.circle")
                            .font(.system(size: 13, weight: .semibold))

                        Text(capacityDisplayMode.toggleTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.codexInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.codexCardRaised)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.codexStroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            ForEach(viewModel.snapshot(for: account)?.meters ?? []) { meter in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meter.title)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.codexInk)

                            if let resetsAt = meter.resetsAt {
                                Text("Resets in \(remainingText(until: resetsAt))")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.codexSecondary)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(capacityDisplayMode.percent(for: meter))%")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.codexInk)

                            Text(capacityDisplayMode.detailLabel(for: meter))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.codexSecondary)
                        }
                    }

                    UsageBar(
                        progress: capacityDisplayMode.progress(for: meter),
                        height: 12,
                        fill: meterFillColor(for: meter),
                        track: Color.codexTrack
                    )
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.codexCardRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.codexStroke, lineWidth: 1)
                )
            }
        }
    }

    private var accountsSection: some View {
        MenuSectionCard {
            Text("Accounts")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)

            ForEach(viewModel.accounts) { account in
                AccountListRow(
                    account: account,
                    displayedEmail: viewModel.displayedEmail(for: account),
                    organizationName: account.currentOrganizationDisplayName,
                    snapshot: viewModel.snapshot(for: account),
                    displayMode: capacityDisplayMode,
                    isActive: viewModel.activeAccount?.id == account.id
                ) {
                    viewModel.selectAccount(account.id)
                }
            }
        }
    }

    private var footerActions: some View {
        MenuSectionCard {
            FooterButton(icon: "plus", title: "Add Account") {
                Task {
                    await viewModel.addAccount()
                }
            }

            FooterButton(icon: "dot.radiowaves.left.and.right", title: "Status Page") {
                guard let url = URL(string: "https://status.openai.com") else {
                    return
                }
                NSWorkspace.shared.open(url)
            }

            FooterButton(icon: "doc.on.doc", title: "Copy Diagnostics") {
                viewModel.copyDiagnostics()
            }

            FooterButton(icon: "doc.text.magnifyingglass", title: "Open Log") {
                viewModel.revealDiagnosticsLog()
            }

            FooterButton(
                icon: viewModel.state.showEmails ? "eye.slash" : "eye",
                title: viewModel.state.showEmails ? "Hide Emails" : "Show Emails"
            ) {
                viewModel.toggleShowEmails()
            }

            SettingsLink {
                FooterRowLabel(icon: "gearshape", title: "Settings")
            }
            .buttonStyle(.plain)

            FooterButton(icon: "power", title: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var emptyState: some View {
        MenuSectionCard {
            Text("Codex")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)

            Text("No imported ChatGPT Codex account was found yet.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.codexSecondary)

            if let error = viewModel.transientError {
                diagnosticsErrorBlock(error)
            }

            Button {
                Task {
                    await viewModel.addAccount()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))

                    Text("Add Account")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.codexAccent)
                )
            }
            .buttonStyle(.plain)

            Text("Add Account will first try the account currently logged into Codex, then open browser login if it is already in the list.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.codexSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private var nextCapacityDisplayMode: CapacityDisplayMode {
        capacityDisplayMode == .remaining ? .used : .remaining
    }

    private func updatedText(for accountID: String) -> String {
        if let updatedAt = viewModel.runtimeState(for: accountID).lastUpdatedAt {
            return "Updated \(relativeUpdateText(since: updatedAt))"
        }
        return "Waiting for first refresh"
    }

    private func relativeUpdateText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))

        if seconds < 60 {
            return "just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return minutes == 1 ? "1 min ago" : "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }

        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    private func diagnosticsErrorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.codexDanger)
                .lineLimit(3)

            diagnosticsActions
        }
    }

    private var diagnosticsActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Copy Diagnostics") {
                    viewModel.copyDiagnostics()
                }

                Button("Open Log") {
                    viewModel.revealDiagnosticsLog()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))

            Text(viewModel.diagnosticsLogPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func remainingText(until date: Date) -> String {
        let remaining = max(0, date.timeIntervalSinceNow)
        let hours = Int(remaining) / 3_600
        let minutes = (Int(remaining) % 3_600) / 60
        let days = Int(remaining) / 86_400

        if days >= 2 {
            return "\(days)d"
        }

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(max(minutes, 1))m"
    }

    private func meterFillColor(for meter: UsageMeter) -> Color {
        let remaining = max(0, min(100 - meter.usedPercent, 100))

        if remaining <= 15 {
            return Color.codexDanger
        }

        if remaining <= 35 {
            return Color.codexWarning
        }

        return Color.codexAccent
    }
}

struct StatusBarLabel: View {
    let snapshot: UsageSnapshot?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.codexAccent)

            VStack(spacing: 3) {
                TinyUsageBar(progress: progress(for: "primary"))
                TinyUsageBar(progress: progress(for: "secondary"))
            }

            if isRefreshing {
                Circle()
                    .fill(Color.codexAccent)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
    }

    private func progress(for meterID: String) -> Double {
        guard let snapshot else {
            return 0
        }
        return snapshot.meters.first(where: { $0.id == meterID })?.usedPercent ?? 0
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        Form {
            Section("Accounts") {
                Text("Imported accounts: \(viewModel.accounts.count)")
                Text("Stored at: \(viewModel.storagePath)")
                    .textSelection(.enabled)

                Button("Add Account") {
                    Task {
                        await viewModel.addAccount()
                    }
                }

                Button("Refresh Now") {
                    Task {
                        await viewModel.refreshAll()
                    }
                }
            }

            Section("Codex CLI") {
                Text(viewModel.codexExecutablePath ?? "codex executable not resolved yet")
                    .textSelection(.enabled)
            }

            Section("Diagnostics") {
                Text("Log file: \(viewModel.diagnosticsLogPath)")
                    .textSelection(.enabled)

                Button("Copy Diagnostics") {
                    viewModel.copyDiagnostics()
                }

                Button("Reveal Log In Finder") {
                    viewModel.revealDiagnosticsLog()
                }

                ScrollView {
                    Text(viewModel.diagnosticsReport.isEmpty ? "No diagnostics collected yet." : viewModel.diagnosticsReport)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 180)
            }

            Section("How To Add More Accounts") {
                Text("This app first snapshots the account currently logged into Codex.")
                Text("If that account is already imported, Add Account opens the Codex browser login flow and saves the new account into its own storage.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 520)
    }
}

private struct MenuSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.codexCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.codexStroke, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 8)
    }
}

private struct WorkspaceBadge: View {
    let title: String
    let icon: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(Color.codexInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.codexCardRaised)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.codexStroke, lineWidth: 1)
        )
    }
}

private struct WorkspacePicker: View {
    let account: StoredAccount
    let selectedWorkspace: StoredWorkspace
    let labelTitle: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(account.workspaces) { workspace in
                Button {
                    onSelect(workspace.id)
                } label: {
                    HStack {
                        Text(workspace.menuLabel)
                        if workspace.id == selectedWorkspace.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            WorkspaceBadge(
                title: labelTitle,
                icon: selectedWorkspace.kind == .team ? "building.2.crop.circle" : "person.crop.circle",
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct AccountListRow: View {
    let account: StoredAccount
    let displayedEmail: String
    let organizationName: String
    let snapshot: UsageSnapshot?
    let displayMode: CapacityDisplayMode
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(displayedEmail)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.codexInk)
                            .lineLimit(1)

                        Text(organizationName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.codexSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if isActive {
                            badge(
                                title: "Current",
                                foreground: .white,
                                background: Color.codexAccent
                            )
                        }

                        badge(
                            title: account.plan.title,
                            foreground: Color.codexInk,
                            background: Color.codexTrack
                        )
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    ForEach(displayMeters) { meter in
                        meterSummary(meter)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isActive ? Color.codexAccentSoft : Color.codexCardRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActive ? Color.codexAccent.opacity(0.45) : Color.codexStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var displayMeters: [UsageMeter] {
        let meters = snapshot?.meters ?? []
        guard !meters.isEmpty else { return placeholderMeters }

        var selected: [UsageMeter] = []
        let preferredDurations = [300, 10_080]

        for duration in preferredDurations {
            if let meter = meters.first(where: { $0.windowDurationMinutes == duration }) {
                selected.append(meter)
            }
        }

        for meter in meters where !selected.contains(where: { $0.id == meter.id }) {
            selected.append(meter)
            if selected.count == 2 {
                break
            }
        }

        if selected.count < 2 {
            for placeholder in placeholderMeters where !selected.contains(where: { $0.windowDurationMinutes == placeholder.windowDurationMinutes }) {
                selected.append(placeholder)
                if selected.count == 2 {
                    break
                }
            }
        }

        return Array(selected.prefix(2))
    }

    private func meterSummary(_ meter: UsageMeter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summaryLabel(for: meter))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.codexSecondary)
                .textCase(.uppercase)

            HStack(spacing: 8) {
                UsageBar(
                    progress: displayMode.progress(for: meter),
                    height: 8,
                    fill: meterFillColor(for: meter),
                    track: Color.codexTrack
                )
                .frame(maxWidth: .infinity)

                Text("\(displayMode.percent(for: meter))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codexSecondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholderMeters: [UsageMeter] {
        [
            UsageMeter(id: "placeholder-5h", title: "5 Hours", usedPercent: 0, windowDurationMinutes: 300, resetsAt: nil),
            UsageMeter(id: "placeholder-1w", title: "Weekly", usedPercent: 0, windowDurationMinutes: 10_080, resetsAt: nil)
        ]
    }

    private func summaryLabel(for meter: UsageMeter) -> String {
        switch meter.windowDurationMinutes {
        case 300:
            return "5h"
        case 10_080:
            return "Weekly"
        case 1_440:
            return "Daily"
        case .some(let minutes) where minutes > 0:
            return meter.compactTitle
        default:
            return meter.title
        }
    }

    private func badge(title: String, foreground: Color, background: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
    }

    private func meterFillColor(for meter: UsageMeter) -> Color {
        let remaining = max(0, min(100 - meter.usedPercent, 100))

        if remaining <= 15 {
            return Color.codexDanger
        }

        if remaining <= 35 {
            return Color.codexWarning
        }

        return Color.codexAccent
    }
}

private struct FooterButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FooterRowLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

private struct FooterRowLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22, height: 22, alignment: .center)
                .foregroundStyle(Color.codexSecondary)

            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct UsageBar: View {
    let progress: Double
    let height: CGFloat
    var fill: Color = .codexAccent
    var track: Color = .codexTrack

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)

                Capsule()
                    .fill(fill)
                    .frame(width: max(8, geometry.size.width * max(0, min(progress, 1))))
            }
        }
        .frame(height: height)
    }
}

private struct TinyUsageBar: View {
    let progress: Double

    var body: some View {
        let clampedProgress = max(0, min(progress / 100, 1))

        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.codexTrack.opacity(0.9))
                .frame(width: 34, height: 4)

            Capsule()
                .fill(Color.codexAccent)
                .frame(width: max(3, 34 * clampedProgress), height: 4)
        }
    }
}

private struct ScrollChromeTuner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else {
                return
            }

            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.scrollerStyle = .overlay
            scrollView.scrollerKnobStyle = .dark
            scrollView.hasHorizontalScroller = false
        }
    }
}

private extension Color {
    static let codexAccent = Color(red: 0.70, green: 0.55, blue: 0.28)
    static let codexAccentSoft = Color(red: 0.95, green: 0.91, blue: 0.83)
    static let codexCanvas = Color(red: 0.95, green: 0.94, blue: 0.90)
    static let codexCanvasShadow = Color(red: 0.92, green: 0.90, blue: 0.85)
    static let codexCard = Color(red: 0.99, green: 0.98, blue: 0.96)
    static let codexCardRaised = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let codexStroke = Color.black.opacity(0.07)
    static let codexInk = Color(red: 0.21, green: 0.20, blue: 0.18)
    static let codexSecondary = Color(red: 0.45, green: 0.42, blue: 0.38)
    static let codexTrack = Color(red: 0.88, green: 0.85, blue: 0.79)
    static let codexWarning = Color(red: 0.84, green: 0.55, blue: 0.22)
    static let codexDanger = Color(red: 0.79, green: 0.33, blue: 0.28)
}
