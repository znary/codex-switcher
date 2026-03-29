# Codex Switcher

[中文](#中文) | [English](#english)

## 中文

Codex Switcher 是一个 macOS 菜单栏小工具，用来同时查看多个 ChatGPT Codex 账号的用量、套餐、工作区和重置时间。支持一键切换账号。

### 功能

- 同时导入和管理多个 Codex 账号
- 为每个账号分别保存认证快照，不需要来回手动切换
- 菜单栏里直接查看 5 小时、日、周等窗口的用量
- 支持按账号工作区刷新，并显示每个账号的下次重置时间
- 支持一键切换
- 支持后台自动刷新
- 支持中英文界面

### 截图演示

| 总览面板 | 账号与操作菜单 |
| --- | --- |
| ![Codex Switcher 总览面板](./docs/screenshots/overview-main.jpg) | ![Codex Switcher 账号与操作菜单](./docs/screenshots/overview-actions.jpg) |

### 运行环境

- macOS
- 已安装 `codex` 可执行文件，或安装 Codex 桌面版
- 至少有一个可用的 Codex 登录账号

### 安装方式

1. 打开 [GitHub Releases](https://github.com/znary/codex-switcher/releases) 页面。
2. 下载最新版本里的 `Codex-Switcher.dmg`。
3. 双击打开 `Codex-Switcher.dmg`。
4. 在弹出的安装窗口里，把 `Codex Switcher.app` 拖到 `Applications` 文件夹。
5. 从 `Applications` 打开 `Codex Switcher`。

### 使用方式

1. 如果你是开发者，也可以用 Xcode 打开 [multi-codex-limit-viewer.xcodeproj](./multi-codex-limit-viewer.xcodeproj) 自行构建运行。
2. 第一次启动时，应用会先尝试导入当前 `~/.codex/auth.json` 对应的账号。
3. 点击 `Add Account` 可以拉起新的登录流程，把更多账号保存到独立存储里。
4. 菜单栏面板会显示每个账号的套餐、容量窗口和重置时间。

### 数据与隐私

- 应用始终先使用本机存储。
- 如果构建时启用了 iCloud Documents，应用会额外保留一份 iCloud 副本，供你手动把本地覆盖到 iCloud，或者把 iCloud 覆盖到本地。
- 只有当本机缺少对应文件时，应用才会从 iCloud 自动补齐，不会自动覆盖本机已有数据。
- 可以在设置页删除 iCloud 副本，本机数据不受影响。
- 临时登录目录和诊断日志仍然只保存在本机。
- 本机默认存储路径是 `~/Library/Application Support/MultiCodexLimitViewer`。
- 如果 `codex` 不在默认路径，可以通过环境变量 `CODEX_BINARY_PATH` 指定。

### 开源协议

本项目使用 MIT License，详见 [LICENSE](./LICENSE)。

## English

Codex Switcher is a macOS menu bar app for monitoring multiple ChatGPT Codex accounts in one place, including usage, plan, workspace, and reset timing. One‑click switch.

### Features

- Import and manage multiple Codex accounts
- Keep a separate auth snapshot for each account
- View 5-hour, daily, and weekly usage windows directly from the menu bar
- Refresh per-account workspace data and show the next reset time for every account
- One‑click switch
- Auto-refresh in the background
- English and Simplified Chinese UI

### Screenshots

| Overview Panel | Accounts and Actions |
| --- | --- |
| ![Codex Switcher overview panel](./docs/screenshots/overview-main-en.png) | ![Codex Switcher accounts and actions menu](./docs/screenshots/overview-actions-en.png) |

### Requirements

- macOS
- A working `codex` executable or the Codex desktop app
- At least one valid Codex account

### Installation

1. Open the [GitHub Releases](https://github.com/znary/codex-switcher/releases) page.
2. Download `Codex-Switcher.dmg` from the latest release.
3. Double-click `Codex-Switcher.dmg` to open it.
4. In the installer window, drag `Codex Switcher.app` into the `Applications` folder.
5. Launch `Codex Switcher` from `Applications`.

### Getting Started

1. Developers can also open [multi-codex-limit-viewer.xcodeproj](./multi-codex-limit-viewer.xcodeproj) in Xcode and build the app locally.
2. On first launch, the app tries to import the account from `~/.codex/auth.json`.
3. Use `Add Account` to launch a new login flow and store more accounts independently.
4. The menu bar panel shows each account's plan, capacity windows, and reset time.

### Data and Privacy

- The app always uses local storage first.
- When the app is built with iCloud Documents enabled, it also keeps a separate iCloud copy so you can manually overwrite iCloud with local data, or overwrite local data with iCloud.
- The app only fills files from iCloud when the matching local file is missing. It never overwrites existing local data automatically.
- You can delete the iCloud copy from Settings without affecting local data.
- Temporary login folders and diagnostics logs remain local-only.
- The default local storage path is `~/Library/Application Support/MultiCodexLimitViewer`.
- If `codex` is not in a standard location, set `CODEX_BINARY_PATH`.

### License

This project is released under the MIT License. See [LICENSE](./LICENSE).
