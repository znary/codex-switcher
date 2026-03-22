# Multi Codex Limit Viewer

[中文](#中文) | [English](#english)

## 中文

一个 macOS 菜单栏小工具，用来同时查看多个 ChatGPT Codex 账号的用量、套餐、工作区和重置时间。

### 功能

- 同时导入和管理多个 Codex 账号
- 为每个账号分别保存认证快照，不需要来回手动切换
- 菜单栏里直接查看 5 小时、日、周等窗口的用量
- 支持按账号工作区刷新，并显示每个账号的下次重置时间
- 支持后台自动刷新
- 支持中英文界面

### 运行环境

- macOS
- 已安装 `codex` 可执行文件，或安装 Codex 桌面版
- 至少有一个可用的 Codex 登录账号

### 使用方式

1. 用 Xcode 打开 [multi-codex-limit-viewer.xcodeproj](./multi-codex-limit-viewer.xcodeproj)。
2. 构建并运行应用。
3. 第一次启动时，应用会先尝试导入当前 `~/.codex/auth.json` 对应的账号。
4. 点击 `Add Account` 可以拉起新的登录流程，把更多账号保存到独立存储里。
5. 菜单栏面板会显示每个账号的套餐、容量窗口和重置时间。

### 数据与隐私

- 所有账号快照和应用状态都只保存在本机。
- 默认存储路径是 `~/Library/Application Support/MultiCodexLimitViewer`。
- 如果 `codex` 不在默认路径，可以通过环境变量 `CODEX_BINARY_PATH` 指定。

### 开源协议

本项目使用 MIT License，详见 [LICENSE](./LICENSE)。

## English

A macOS menu bar app for monitoring multiple ChatGPT Codex accounts in one place, including usage, plan, workspace, and reset timing.

### Features

- Import and manage multiple Codex accounts
- Keep a separate auth snapshot for each account
- View 5-hour, daily, and weekly usage windows directly from the menu bar
- Refresh per-account workspace data and show the next reset time for every account
- Auto-refresh in the background
- English and Simplified Chinese UI

### Requirements

- macOS
- A working `codex` executable or the Codex desktop app
- At least one valid Codex account

### Getting Started

1. Open [multi-codex-limit-viewer.xcodeproj](./multi-codex-limit-viewer.xcodeproj) in Xcode.
2. Build and run the app.
3. On first launch, the app tries to import the account from `~/.codex/auth.json`.
4. Use `Add Account` to launch a new login flow and store more accounts independently.
5. The menu bar panel shows each account's plan, capacity windows, and reset time.

### Data and Privacy

- All account snapshots and app state stay on your Mac.
- The default storage path is `~/Library/Application Support/MultiCodexLimitViewer`.
- If `codex` is not in a standard location, set `CODEX_BINARY_PATH`.

### License

This project is released under the MIT License. See [LICENSE](./LICENSE).
