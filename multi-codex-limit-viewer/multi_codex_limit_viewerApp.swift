//
//  multi_codex_limit_viewerApp.swift
//  multi-codex-limit-viewer
//
//  Created by liuzhuangm4 on 2026/3/21.
//

import SwiftUI

@main
struct multi_codex_limit_viewerApp: App {
    @StateObject private var viewModel = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(viewModel: viewModel)
        } label: {
            StatusBarLabel(
                snapshot: viewModel.activeSnapshot,
                isRefreshing: viewModel.isRefreshing
            )
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: MenuBarViewModel.settingsWindowIdentifier) {
            SettingsView(viewModel: viewModel)
        }
        .defaultSize(width: 900, height: 680)
    }
}
