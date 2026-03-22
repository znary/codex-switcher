//
//  MenuBarViews.swift
//  multi-codex-limit-viewer
//

import AppKit
import SwiftUI

private let appTitle = "Codex Switcher"

private enum CapacityDisplayMode: String {
    case remaining
    case used

    var titleKey: AppTextKey {
        switch self {
        case .remaining:
            return .capacityRemaining
        case .used:
            return .capacityUsed
        }
    }

    var toggleTitleKey: AppTextKey {
        switch self {
        case .remaining:
            return .capacityShowUsed
        case .used:
            return .capacityShowRemaining
        }
    }

    var summaryTextKey: AppTextKey {
        switch self {
        case .remaining:
            return .capacitySummaryRemaining
        case .used:
            return .capacitySummaryUsed
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

    var detailLabelKey: AppTextKey {
        switch self {
        case .remaining:
            return .capacityLeft
        case .used:
            return .capacityUsedSuffix
        }
    }
}

struct MenuBarRootView: View {
    @AppStorage("capacityDisplayMode") private var capacityDisplayModeRawValue = CapacityDisplayMode.remaining.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: MenuBarViewModel
    @State private var accountRowFrames: [String: CGRect] = [:]
    @State private var draggingAccountID: String?
    @State private var draggingPointerY: CGFloat?
    @State private var draggingPointerOffsetY: CGFloat = 0
    @State private var isReorderGestureActive = false
    @State private var accountSelectionSuppressedUntil = Date.distantPast

    private let accountsListCoordinateSpace = "MenuBarRootView.accounts"

    private var capacityDisplayMode: CapacityDisplayMode {
        CapacityDisplayMode(rawValue: capacityDisplayModeRawValue) ?? .remaining
    }

    var body: some View {
        Group {
            if let activeAccount = viewModel.activeAccount {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header(account: activeAccount)
                        usageSection(account: activeAccount)
                        accountsSection
                        footerActions
                    }
                    .padding(18)
                }
                .background(ScrollChromeTuner())
                .frame(width: 388, height: 700)
            } else {
                ScrollView(showsIndicators: false) {
                    emptyState
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(ScrollChromeTuner())
                .frame(width: 388, height: viewModel.transientError == nil ? 300 : 420)
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

    private func header(account: StoredAccount) -> some View {
        MenuSectionCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(appTitle)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.codexInk)

                    Text(updatedText(for: account.id))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.codexSecondary.opacity(0.72))
                        .padding(.leading, 6)

                    if let error = viewModel.runtimeState(for: account.id).lastError {
                        diagnosticsErrorBlock(error)
                    } else if let transientError = viewModel.transientError {
                        diagnosticsErrorBlock(transientError)
                    }
                }

                Spacer(minLength: 0)

                refreshButton
                    .padding(.top, 2)
            }
        }
    }

    private func usageSection(account: StoredAccount) -> some View {
        MenuSectionCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    Text(viewModel.text(.capacity))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.codexInk)

                    Spacer(minLength: 0)

                    capacityAccountHeader(account: account)
                }
            }

            ForEach(viewModel.snapshot(for: account)?.meters ?? []) { meter in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.meterTitle(for: meter))
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.codexInk)

                            if let resetsAt = meter.resetsAt {
                                Text(viewModel.resetsInText(until: resetsAt))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.codexSecondary)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(capacityDisplayMode.percent(for: meter))%")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.codexInk)

                            Text(viewModel.text(capacityDisplayMode.detailLabelKey))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.codexSecondary)
                        }
                        .padding(.top, -3)
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
            Text(viewModel.text(.accounts))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)

            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.accounts) { account in
                        accountRow(account, isInteractive: true)
                            .background(AccountRowFrameReader(accountID: account.id))
                            .opacity(draggingAccountID == account.id ? 0.001 : 1)
                            .simultaneousGesture(accountReorderGesture(for: account))
                    }
                }

                if let draggedAccount {
                    accountRow(draggedAccount, isInteractive: false)
                        .allowsHitTesting(false)
                        .offset(y: draggedAccountOverlayY)
                        .zIndex(2)
                }
            }
            .coordinateSpace(name: accountsListCoordinateSpace)
            .onPreferenceChange(AccountRowFramePreferenceKey.self) { frames in
                accountRowFrames = frames

                if let draggingAccountID,
                   !viewModel.accounts.contains(where: { $0.id == draggingAccountID }) {
                    clearAccountDrag()
                }
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: StoredAccount, isInteractive: Bool) -> some View {
        let isDragging = draggingAccountID == account.id
        let row = AccountListRow(
            displayedEmail: viewModel.displayedEmail(for: account),
            organizationName: viewModel.accountSubtitle(for: account),
            snapshot: viewModel.snapshot(for: account),
            displayMode: capacityDisplayMode,
            isActive: viewModel.activeAccount?.id == account.id,
            currentBadgeTitle: viewModel.text(.current),
            planTitle: viewModel.localizedPlanTitle(for: account.plan),
            meterSummaryLabel: { meter in
                viewModel.meterSummaryLabel(for: meter)
            },
            meterResetLabel: { meter in
                guard let resetsAt = meter.resetsAt else {
                    return nil
                }
                return viewModel.resetsInText(until: resetsAt)
            }
        ) {
            guard isInteractive,
                  !isReorderGestureActive,
                  Date() >= accountSelectionSuppressedUntil else {
                return
            }

            viewModel.selectAccount(account.id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(isDragging ? 1.015 : 1)
        .shadow(
            color: Color.black.opacity(isDragging ? 0.12 : 0),
            radius: isDragging ? 18 : 0,
            x: 0,
            y: isDragging ? 12 : 0
        )
        .zIndex(isDragging ? 2 : 0)

        if isInteractive {
            row.contextMenu {
                Button(role: .destructive) {
                    clearAccountDrag()
                    viewModel.deleteAccount(account.id)
                } label: {
                    Label(viewModel.text(.deleteAccount), systemImage: "trash")
                }
            }
        } else {
            row
        }
    }

    private var draggedAccount: StoredAccount? {
        guard let draggingAccountID else {
            return nil
        }

        return viewModel.accounts.first(where: { $0.id == draggingAccountID })
    }

    private var draggedAccountOverlayY: CGFloat {
        guard let draggingPointerY else {
            return 0
        }

        return draggingPointerY - draggingPointerOffsetY
    }

    private var footerActions: some View {
        MenuSectionCard {
            FooterButton(icon: "plus", title: viewModel.text(.addAccount)) {
                dismissMenuBarPanel {
                    viewModel.addAccount()
                }
            }

            FooterButton(icon: "tray.and.arrow.down", title: viewModel.text(.importCurrentAccount)) {
                Task {
                    await viewModel.importCurrentAccount()
                }
            }

            FooterButton(icon: "dot.radiowaves.left.and.right", title: viewModel.text(.statusPage)) {
                dismissMenuBarPanel {
                    guard let url = URL(string: "https://status.openai.com") else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
            }

            FooterButton(icon: "chart.bar", title: viewModel.text(.usageDashboard)) {
                dismissMenuBarPanel {
                    guard let url = URL(string: "https://chatgpt.com/codex/settings/usage") else {
                        return
                    }
                    NSWorkspace.shared.open(url)
                }
            }

            FooterButton(
                icon: viewModel.state.showEmails ? "eye.slash" : "eye",
                title: viewModel.state.showEmails ? viewModel.text(.hideEmails) : viewModel.text(.showEmails)
            ) {
                viewModel.toggleShowEmails()
            }

            FooterButton(icon: "arrow.left.arrow.right.circle", title: viewModel.text(capacityDisplayMode.toggleTitleKey)) {
                capacityDisplayModeRawValue = nextCapacityDisplayMode.rawValue
            }

            FooterButton(icon: "gearshape", title: viewModel.text(.settings)) {
                openSettingsPanel()
            }

            FooterButton(icon: "power", title: viewModel.text(.quit)) {
                dismissMenuBarPanel {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private var emptyState: some View {
        MenuSectionCard {
            Text(appTitle)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.text(.noImportedAccount))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.codexSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.transientError {
                diagnosticsErrorBlock(error)
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    viewModel.addAccount()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))

                        Text(viewModel.text(.addAccount))
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
                .buttonStyle(PrimaryHoverButtonStyle())

                Button {
                    Task {
                        await viewModel.importCurrentAccount()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))

                        Text(viewModel.text(.importCurrentAccount))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.codexInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
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
                .buttonStyle(CapsuleHoverButtonStyle())
            }

            if viewModel.transientError == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.text(.howToAddMoreAccountsLine1))
                    Text(viewModel.text(.howToAddMoreAccountsLine2))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.codexSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
    }

    private var nextCapacityDisplayMode: CapacityDisplayMode {
        capacityDisplayMode == .remaining ? .used : .remaining
    }

    private func openSettingsPanel() {
        openWindow(id: MenuBarViewModel.settingsWindowIdentifier)
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
    }

    private func dismissMenuBarPanel(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.async(execute: action)
    }

    private func updatedText(for accountID: String) -> String {
        viewModel.updatedText(since: viewModel.runtimeState(for: accountID).lastUpdatedAt)
    }

    private func diagnosticsErrorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.codexDanger)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            diagnosticsActions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.codexCardRaised.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.codexDanger.opacity(0.18), lineWidth: 1)
        )
    }

    private var diagnosticsActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(viewModel.text(.copyDiagnostics)) {
                    viewModel.copyDiagnostics()
                }

                Button(viewModel.text(.openLog)) {
                    viewModel.revealDiagnosticsLog()
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(HoverLinkButtonStyle())

            Text(viewModel.diagnosticsLogPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.codexSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var refreshButton: some View {
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

                Text(viewModel.isRefreshing ? viewModel.text(.refreshing) : viewModel.text(.refresh))
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
        .buttonStyle(CapsuleHoverButtonStyle())
        .disabled(viewModel.isRefreshing)
    }

    private func capacityAccountHeader(account: StoredAccount) -> some View {
        let visibleWorkspaces = account.workspaces.filter { workspace in
            viewModel.workspaceMenuLabel(for: workspace) != nil
        }

        return VStack(alignment: .trailing, spacing: 6) {
            Text(viewModel.displayedEmail(for: account))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            if
                visibleWorkspaces.count > 1,
                let selectedWorkspace = account.selectedWorkspace,
                visibleWorkspaces.contains(where: { $0.id == selectedWorkspace.id }),
                let labelTitle = viewModel.accountSubtitle(for: account)
            {
                WorkspacePicker(
                    workspaces: visibleWorkspaces,
                    selectedWorkspace: selectedWorkspace,
                    labelTitle: labelTitle,
                    menuLabel: { workspace in
                        viewModel.workspaceMenuLabel(for: workspace) ?? ""
                    },
                    onSelect: { workspaceID in
                        viewModel.selectWorkspace(workspaceID, for: account.id)
                    }
                )
            } else if let organizationName = viewModel.accountSubtitle(for: account) {
                Text(organizationName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codexSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
    }

    private func accountReorderGesture(for account: StoredAccount) -> some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(accountsListCoordinateSpace)))
            .onChanged { value in
                guard viewModel.accounts.count > 1 else {
                    return
                }

                switch value {
                case .second(true, let drag?):
                    beginDraggingAccountIfNeeded(account.id, pointerY: drag.startLocation.y)
                    draggingPointerY = drag.location.y
                    moveDraggedAccount(account.id, pointerY: drag.location.y)
                default:
                    break
                }
            }
            .onEnded { _ in
                clearAccountDrag()
            }
    }

    private func beginDraggingAccountIfNeeded(_ accountID: String, pointerY: CGFloat) {
        guard draggingAccountID != accountID else {
            return
        }

        isReorderGestureActive = true
        draggingAccountID = accountID
        draggingPointerY = pointerY

        if let frame = accountRowFrames[accountID] {
            draggingPointerOffsetY = pointerY - frame.minY
        } else {
            draggingPointerOffsetY = 0
        }
    }

    private func moveDraggedAccount(_ accountID: String, pointerY: CGFloat) {
        let orderedOtherAccounts = viewModel.accounts.filter { $0.id != accountID }
        let targetIndex = orderedOtherAccounts.firstIndex { account in
            guard let frame = accountRowFrames[account.id] else {
                return false
            }
            return pointerY < frame.midY
        } ?? orderedOtherAccounts.count

        viewModel.moveAccount(accountID, toIndex: targetIndex)
    }

    private func clearAccountDrag() {
        if isReorderGestureActive {
            accountSelectionSuppressedUntil = Date().addingTimeInterval(0.35)
        }

        isReorderGestureActive = false
        draggingAccountID = nil
        draggingPointerY = nil
        draggingPointerOffsetY = 0
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
    private let githubURL = URL(string: "https://github.com/znary/codex-switcher")!
    @ObservedObject var viewModel: MenuBarViewModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsPanelSection(title: viewModel.text(.general)) {
                        SettingsPanelRow {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(viewModel.text(.startAtLogin))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.codexInk)

                                    Text(viewModel.text(.startAtLoginDescription))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.codexSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)

                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { viewModel.launchAtLoginEnabled },
                                        set: { viewModel.setLaunchAtLogin($0) }
                                    )
                                )
                                .labelsHidden()
                                .toggleStyle(SwitchToggleStyle())
                            }
                        }

                        SettingsPanelDivider()

                        SettingsPanelRow {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .center, spacing: 12) {
                                    Text(viewModel.text(.refreshInterval))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.codexInk)

                                    Spacer(minLength: 12)

                                    Picker(
                                        viewModel.text(.refreshInterval),
                                        selection: Binding(
                                            get: { viewModel.autoRefreshInterval },
                                            set: { viewModel.setAutoRefreshInterval($0) }
                                        )
                                    ) {
                                        ForEach(viewModel.autoRefreshIntervalOptions) { option in
                                            Text(viewModel.autoRefreshIntervalDisplayName(for: option))
                                                .tag(option)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }

                                Text(viewModel.text(.chooseRefreshInterval))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.codexSecondary)
                            }
                        }
                    }

                    SettingsPanelSection(title: viewModel.text(.language)) {
                        SettingsPanelRow {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .center, spacing: 12) {
                                    Text(viewModel.text(.language))
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.codexInk)

                                    Spacer(minLength: 12)

                                    Picker(
                                        viewModel.text(.language),
                                        selection: Binding(
                                            get: { viewModel.languagePreference },
                                            set: { viewModel.setLanguage($0) }
                                        )
                                    ) {
                                        ForEach(viewModel.languageOptions) { option in
                                            Text(viewModel.languageDisplayName(for: option))
                                                .tag(option)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }

                                Text(viewModel.text(.chooseAppLanguage))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.codexSecondary)
                            }
                        }
                    }

                    SettingsPanelSection(title: viewModel.text(.codexCLI)) {
                        SettingsPanelRow {
                            Text(viewModel.codexExecutablePath ?? viewModel.text(.codexExecutableUnresolved))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Color.codexInk)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    SettingsPanelSection(title: viewModel.text(.diagnostics)) {
                        SettingsPanelRow {
                            HStack(spacing: 12) {
                                SettingsActionPill(title: viewModel.text(.copyDiagnostics)) {
                                    viewModel.copyDiagnostics()
                                }

                                SettingsActionPill(title: viewModel.text(.revealLogInFinder)) {
                                    viewModel.revealDiagnosticsLog()
                                }
                            }
                        }
                    }

                    SettingsPanelSection(title: viewModel.text(.howToAddMoreAccounts)) {
                        SettingsPanelRow {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(viewModel.text(.howToAddMoreAccountsLine1))
                                Text(viewModel.text(.howToAddMoreAccountsLine2))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.codexInk)
                        }
                    }

                    SettingsPanelSection(title: viewModel.text(.about)) {
                        SettingsPanelRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(appDisplayName)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.codexInk)

                                Text(viewModel.text(.aboutDescription))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.codexSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        SettingsPanelDivider()

                        SettingsPanelRow {
                            VStack(alignment: .leading, spacing: 14) {
                                settingsInfoRow(title: viewModel.text(.version), value: appVersionLabel)
                                settingsLinkRow(title: viewModel.text(.github), url: githubURL)
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: max(geometry.size.width, 0), alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ScrollChromeTuner())
            .background(
                LinearGradient(
                    colors: [Color.codexCanvas, Color.codexCanvasShadow],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .background(WindowConfigurator(identifier: MenuBarViewModel.settingsWindowIdentifier))
    }

    private var appDisplayName: String {
        appTitle
    }

    private var appVersionLabel: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? version
        return build == version ? version : "\(version) (\(build))"
    }

    private func settingsInfoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.codexSecondary)
                .textCase(.uppercase)

            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.codexInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsLinkRow(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.codexSecondary)
                .textCase(.uppercase)

            Link(destination: url) {
                Text(url.absoluteString)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.blue)
                    .underline()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SettingsPanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.codexInk)

            VStack(alignment: .leading, spacing: 0, content: content)
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
}

private struct SettingsPanelRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
    }
}

private struct SettingsPanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 18)
    }
}

private struct SettingsActionPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.codexInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.codexCardRaised)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.codexStroke, lineWidth: 1)
                )
        }
        .buttonStyle(CapsuleHoverButtonStyle())
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

    @State private var isHovered = false

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
        .scaleEffect(isHovered ? 1.01 : 1)
        .offset(y: isHovered ? -1 : 0)
        .brightness(isHovered ? 0.015 : 0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct WorkspacePicker: View {
    let workspaces: [StoredWorkspace]
    let selectedWorkspace: StoredWorkspace
    let labelTitle: String
    let menuLabel: (StoredWorkspace) -> String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(workspaces) { workspace in
                Button {
                    onSelect(workspace.id)
                } label: {
                    HStack {
                        Text(menuLabel(workspace))
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
    }
}

private struct AccountListRow: View {
    let displayedEmail: String
    let organizationName: String?
    let snapshot: UsageSnapshot?
    let displayMode: CapacityDisplayMode
    let isActive: Bool
    let currentBadgeTitle: String
    let planTitle: String
    let meterSummaryLabel: (UsageMeter) -> String
    let meterResetLabel: (UsageMeter) -> String?
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
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)

                        if let organizationName {
                            Text(organizationName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.codexSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        if isActive {
                            badge(
                                title: currentBadgeTitle,
                                foreground: .white,
                                background: Color.codexAccent
                            )
                        }

                        badge(
                            title: planTitle,
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
        .buttonStyle(HoverLiftButtonStyle())
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text(meterSummaryLabel(meter))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.codexSecondary)
                    .textCase(.uppercase)

                Spacer(minLength: 0)

                Text("\(displayMode.percent(for: meter))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.codexSecondary)
                    .frame(alignment: .trailing)
                    .padding(.top, -1)
            }

            UsageBar(
                progress: displayMode.progress(for: meter),
                height: 8,
                fill: meterFillColor(for: meter),
                track: Color.codexTrack
            )
            .frame(maxWidth: .infinity)

            if let resetLabel = meterResetLabel(meter) {
                Text(resetLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.codexSecondary)
                    .lineLimit(1)
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
        .buttonStyle(HoverLiftButtonStyle())
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

private struct AccountRowFrameReader: View {
    let accountID: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: AccountRowFramePreferenceKey.self,
                    value: [accountID: proxy.frame(in: .named("MenuBarRootView.accounts"))]
                )
        }
    }
}

private struct AccountRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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

private struct WindowConfigurator: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }

            if window.identifier?.rawValue != identifier {
                window.identifier = NSUserInterfaceItemIdentifier(identifier)
            }

            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 720, height: 560)

            var behavior = window.collectionBehavior
            behavior.insert(.moveToActiveSpace)
            window.collectionBehavior = behavior
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

private struct HoverLiftButtonStyle: ButtonStyle {
    var hoveredScale: CGFloat = 1.01
    var pressedScale: CGFloat = 0.985
    var hoveredOffset: CGFloat = -1
    var hoveredBrightness: Double = 0.015

    func makeBody(configuration: Configuration) -> some View {
        HoverLiftButtonBody(
            configuration: configuration,
            hoveredScale: hoveredScale,
            pressedScale: pressedScale,
            hoveredOffset: hoveredOffset,
            hoveredBrightness: hoveredBrightness
        )
    }
}

private struct HoverLiftButtonBody: View {
    let configuration: HoverLiftButtonStyle.Configuration
    let hoveredScale: CGFloat
    let pressedScale: CGFloat
    let hoveredOffset: CGFloat
    let hoveredBrightness: Double

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : (isHovered ? hoveredScale : 1))
            .offset(y: configuration.isPressed ? 0 : (isHovered ? hoveredOffset : 0))
            .brightness(isHovered ? hoveredBrightness : 0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

private struct CapsuleHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLiftButtonBody(
            configuration: configuration,
            hoveredScale: 1.015,
            pressedScale: 0.985,
            hoveredOffset: -1.5,
            hoveredBrightness: 0.02
        )
    }
}

private struct PrimaryHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLiftButtonBody(
            configuration: configuration,
            hoveredScale: 1.02,
            pressedScale: 0.985,
            hoveredOffset: -1.5,
            hoveredBrightness: 0.01
        )
    }
}

private struct HoverLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLinkButtonBody(configuration: configuration)
    }
}

private struct HoverLinkButtonBody: View {
    let configuration: HoverLinkButtonStyle.Configuration

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.codexInk : Color.codexSecondary)
            .underline(isHovered, color: Color.codexSecondary)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.16), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
