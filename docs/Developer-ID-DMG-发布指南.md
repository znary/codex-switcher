# Developer ID 签名与公证 DMG 发布指南

适用目标：不走 Mac App Store，直接发布一个用户双击即可安装、不会因为“未识别开发者”或“无法验证是否包含恶意软件”而被 Gatekeeper 拦住的 macOS App。

这份仓库当前走的是这条线：

- 关闭 App Sandbox。
- 保留 Hardened Runtime。
- 使用 `Developer ID` 签名。
- 对最终 DMG 做 notarization 和 staple。

只做签名不够。要尽量避免用户看到“不安全、无法打开”的提示，必须同时满足下面两点：

1. App 和 DMG 都有有效签名。
2. 最终给用户下载的 DMG 已经 notarize，并且最好已经 staple。

Apple 官方参考：

- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 1. 先准备好什么

你至少需要：

- Apple Developer Program 账号。
- Keychain 里可用的 `Developer ID Application` 证书。
- Xcode 最新稳定版。
- 一个 App Store Connect app-specific password，用来给 `notarytool` 上传。

先检查本机有没有 Developer ID 证书：

```bash
security find-identity -v -p codesigning | rg "Developer ID Application"
```

如果这里没有输出，先去 Apple Developer 后台创建 Developer ID 证书，并导入到当前 Mac。

## 2. 确认工程状态

这个仓库已经按直发 DMG 的方向改好了：

- 关闭了 `App Sandbox`
- 保留了 `Hardened Runtime`

如果你后面又手动改过工程，发布前至少确认：

```bash
rg -n "ENABLE_APP_SANDBOX|ENABLE_HARDENED_RUNTIME" multi-codex-limit-viewer.xcodeproj/project.pbxproj
```

你应该看到：

- `ENABLE_APP_SANDBOX = NO`
- `ENABLE_HARDENED_RUNTIME = YES`

## 3. 第一次配置 notarization 凭据

先在 Apple ID 里创建 app-specific password。

然后把凭据存进本机 keychain：

```bash
xcrun notarytool store-credentials "codex-notary" \
  --apple-id "<你的 Apple ID>" \
  --team-id "24D7733HKN" \
  --password "<你的 app-specific password>"
```

成功后，这台机器以后可以直接复用 `codex-notary` 这个 profile。

## 4. 一键打包签名后的 DMG

仓库里已经放了脚本：

- [scripts/package_direct_dmg.sh](/Users/liuzhuangm4/develop/codexlimitviewer/multi-codex-limit-viewer/scripts/package_direct_dmg.sh)

最常用的运行方式：

```bash
cd /Users/liuzhuangm4/develop/codexlimitviewer/multi-codex-limit-viewer
NOTARY_PROFILE=codex-notary ./scripts/package_direct_dmg.sh
```

脚本会按下面顺序执行：

1. `xcodebuild archive`
2. `xcodebuild -exportArchive`，按 `developer-id` 方法导出 `.app`
3. 校验导出的 `.app` 签名
4. 创建 DMG
5. 给 DMG 做 `codesign`
6. 提交 DMG 到 Apple notarization
7. 对 DMG 做 `staple`
8. 本地执行 Gatekeeper 验证

默认输出位置：

- App：`build/direct/export/multi-codex-limit-viewer.app`
- DMG：`build/direct/Codex-Switcher.dmg`

## 5. 如果你的证书名字不是默认值

脚本会自动从 keychain 找第一张 `Developer ID Application` 证书。

如果你的环境里有多张证书，建议显式指定：

```bash
DMG_SIGN_IDENTITY="Developer ID Application: Your Name (24D7733HKN)" \
NOTARY_PROFILE=codex-notary \
./scripts/package_direct_dmg.sh
```

## 6. 如果你只想先本地出一个 DMG

可以先不 notarize：

```bash
./scripts/package_direct_dmg.sh
```

但要注意：

- 这只是开发自测用。
- 这种 DMG 发给用户后，仍然可能被 Gatekeeper 拦住。
- 真正对外发布前，必须带 `NOTARY_PROFILE` 重新跑完整流程。

## 7. 怎样确认用户不会被 Gatekeeper 拦住

脚本最后已经会跑这两个检查：

```bash
spctl -a -vv -t exec build/direct/export/multi-codex-limit-viewer.app
spctl -a -vv -t open build/direct/Codex-Switcher.dmg
```

你还应该再做一次人工验证：

1. 把最终 DMG 上传到你真实要分发的位置。
2. 用浏览器重新下载这个 DMG，不要直接拿本地生成文件替代。
3. 在另一台没装过这个 App 的 Mac 上双击打开。
4. 确认系统没有出现“无法验证开发者”或“包含恶意软件，无法打开”的提示。

如果 notarization 没成功、ticket 没 stapled，或者发布时换了文件，都会导致最终体验和你本机不一样。

## 8. 常见失败点

### 8.1 只有签名，没有 notarize

结果：

- 本机也许能打开。
- 用户机器上仍然可能看到安全拦截。

### 8.2 导出的是 `.app`，但给用户发的是后来重新打包过的另一个 DMG

结果：

- 你 notarize 的不是最终分发文件。
- 用户下载后仍然可能被 Gatekeeper 拦。

原则很简单：

- 你发出去的最终 DMG，就是你提交 notarization 和 staple 的那个 DMG。

### 8.3 Developer ID 证书不在当前机器

结果：

- `xcodebuild -exportArchive` 或 `codesign` 会直接失败。

先用下面命令检查：

```bash
security find-identity -v -p codesigning | rg "Developer ID Application"
```

### 8.4 notarization 失败

先看日志：

```bash
xcrun notarytool log <submission-id> --keychain-profile codex-notary notary-log.json
```

最常见的是：

- 某个二进制没签好
- 包里混入了不该放在可执行目录里的资源
- 你提交的不是最终分发容器

## 9. 推荐发布口径

如果你要把这套流程固定下来，建议每次发布都保持这几个动作不变：

1. 用同一个 Xcode 版本。
2. 用同一个 `Developer ID Application` 证书。
3. 用脚本统一生成最终 DMG。
4. 对最终 DMG notarize。
5. staple 之后再上传。
6. 上传后重新下载验证一次。

只要你走的是：

- `Developer ID` 签名
- notarization 成功
- staple 成功
- 发出去的是同一个最终 DMG

正常用户双击打开时，就不应该再遇到“应用不安全导致无法打开”的那类拦截。
