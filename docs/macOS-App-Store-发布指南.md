# macOS App Store 发布指南

适用对象：第一次发布 macOS App，已经有 Apple Developer 账号，但还没有走过上架流程的人。

本文按“能真正发出去”为目标来写，尽量少说空话，直接给操作顺序、材料清单、常见坑和这个仓库当前需要补的项。

## 1. 先说结论

把一个 macOS App 发到 Mac App Store，实际要做的事可以分成 7 步：

1. 确认开发者账号、协议、税务和收款状态没卡住。
2. 在 Xcode 把工程整理到“可上架”的状态。
3. 在 App Store Connect 创建 App 记录。
4. 准备截图、文案、隐私政策、年龄分级等元数据。
5. Archive 并上传构建包。
6. 在 App Store Connect 选 build、填审核信息、提交审核。
7. 通过审核后选择立即发布、手动发布，或者定时发布。

如果你只想走最稳的第一次上架路径，建议用这条线：

1. 先把工程补到可以 Archive。
2. 在 App Store Connect 创建 macOS App 记录。
3. 先传一个内部测试 build。
4. 把截图、文案、隐私、年龄分级全部补齐。
5. 再提交正式审核。

## 2. 这次上架你需要准备什么

最低准备清单：

- 一个有效的 Apple Developer Program 账号。
- 一个确定不会再乱改的 Bundle ID。
- App 图标。
- macOS 截图。
- App 名称、副标题、描述、关键词、支持链接、营销文案。
- 隐私政策 URL。
- App Privacy 数据收集说明。
- 年龄分级。
- 审核联系人信息。
- 如果 App 需要登录，审核用账号或演示模式。

如果你要收费，还额外需要：

- App Store Connect 里由 Account Holder 接受 Paid Apps Agreement。
- 税务和收款信息可用。

## 3. 这个仓库当前状态

基于本地工程的当前状态，我先帮你看了一眼：

- `DEVELOPMENT_TEAM` 已经配置了。
- `PRODUCT_BUNDLE_IDENTIFIER` 现在是 `com.zzz.codex.switcher`。
- 目前仓库里没有发现 `.entitlements` 文件。
- `project.pbxproj` 里也没有看到 `CODE_SIGN_ENTITLEMENTS`。

这意味着：如果你要上 Mac App Store，当前工程最需要优先补的是 **App Sandbox / entitlements**。

原因很简单，Apple 官方说明里写得很明确：**通过 Mac App Store 分发的 macOS App 必须启用 App Sandbox**。

所以，别一上来就想着点上传。先把工程补到“能上架”的形态，否则后面很容易在签名、能力、审核权限上出问题。

## 4. 阶段一：先把账号和后台状态清干净

### 4.1 Apple Developer 账号

你已经有账号，这一步重点不是“有没有”，而是“能不能正常提交”。

你需要检查：

- Apple Developer Program 没过期。
- App Store Connect 能正常进入。
- 账号没有挂着未完成的合规审核。
- 如果你是团队账号，确认你在 App Store Connect 至少有足够权限。

如果 Apple 正在做 compliance review，可能会影响你签协议、改税务、或者提交新 App。

### 4.2 协议、税务、收款

这一步很容易被忽略，但经常卡人。

你要在 App Store Connect 里确认：

- 最新协议已经接受。
- 如果要收费，Paid Apps Agreement 已接受。
- 税务信息完整。
- 银行账户信息完整。

Apple 官方说明里提到，如果 Paid Apps Agreement 没被 Account Holder 接受，你的 App 只能免费，不能作为收费 App 提交。

## 5. 阶段二：先把 Xcode 工程补到“可上架”

这一段是第一次发 macOS App 最重要的部分。

### 5.1 Bundle ID 不要乱改

Bundle ID 一旦上传过 build，就不要随便改了。App Store Connect 里的 App 记录和你上传的 build 必须一致。

建议你在正式创建 App 记录前就决定好：

- 产品名
- Bundle ID
- App 对外显示名称

如果 `com.zzz.codex.switcher` 只是临时名字，先改干净，再去 App Store Connect 创建正式记录。

### 5.2 版本号和构建号

至少要区分这两个值：

- `Version`：例如 `1.0.0`
- `Build`：例如 `1`

后续每次重新上传二进制，`Build` 都要递增。

### 5.3 App Sandbox

这是 Mac App Store 的硬要求。

你需要做的事：

1. 给工程加一个 entitlements 文件。
2. 开启 App Sandbox。
3. 只勾选你真的需要的权限。

常见能力示例：

- 文件访问
- 网络访问
- 用户选择文件读写
- 下载目录访问
- 通知

原则很简单：**最小权限**。你勾多了，审核会看；你勾少了，运行会坏。

### 5.4 签名

第一次发 App，最省心的方式是：

- 用 Xcode 自动签名。
- 在 Signing & Capabilities 里选你的 Team。
- 让 Xcode 自动生成需要的配置。

如果你没有特殊签名流程，不建议第一次上架就自己手搓一整套证书和 profile。

### 5.5 图标、名称、分类、最低系统版本

这几项要尽早定：

- App Icon
- Display Name
- Category
- Deployment Target

App 图标和产品页素材最好保持一致，不要一个叫 A，一个看起来像 B。

### 5.6 本地稳定性检查

在提交前，你至少要自己做这几类测试：

- 冷启动
- 重启 App
- 主流程完整走通
- 网络异常
- 权限弹窗
- 菜单栏常驻逻辑
- 多账号切换
- 长时间运行

Apple 审核最烦看到的是：

- 崩溃
- 明显卡死
- 按钮没反应
- 假链接
- 占位文案

## 6. 阶段三：在 App Store Connect 创建 App 记录

### 6.1 创建 App

在 App Store Connect 里创建新 App 时，通常会填这些：

- Name
- Primary Language
- Bundle ID
- SKU

注意：

- `Bundle ID` 必须和 Xcode 工程一致。
- `SKU` 只是你内部识别用，用户看不到，但创建后不要指望再改。

### 6.2 添加 macOS 平台

如果这是一个新的 App 记录，你要确认已经为它添加了 `macOS` 平台版本。

### 6.3 App Information

这里通常要补：

- App 名称
- 副标题
- 分类
- 年龄分级
- 内容版权

Apple 官方帮助里说明，年龄分级是必填，而且 **Unrated 不能发布到 App Store**。

## 7. 阶段四：准备产品页素材和元数据

这部分非常耗时间，建议你一次性整理好。

### 7.1 必备元数据

至少准备下面这些：

- App Name
- Subtitle
- Description
- Keywords
- Support URL
- Marketing URL（可选但建议准备）
- Privacy Policy URL
- Copyright

Apple 官方文档里明确提到：

- App 名称有长度限制。
- Subtitle 有长度限制。
- macOS App 需要 Privacy Policy URL。

### 7.2 macOS 截图要求

Mac App 的截图是必需项。

Apple 当前给出的 macOS 截图要求是：

- 1 到 10 张
- 格式：`.jpeg`、`.jpg`、`.png`
- 长宽比：`16:10`
- 尺寸四选一：
  - `1280 x 800`
  - `1440 x 900`
  - `2560 x 1600`
  - `2880 x 1800`

实操建议：

- 先用一套统一尺寸，不要混着来。
- 截图内容尽量覆盖核心功能，不要全是欢迎页。
- 第一张截图最重要，把主要卖点放进去。
- 如果你支持中英文，最好两套本地化截图一起做。

### 7.3 隐私政策和 App Privacy

这是两件事，不要混。

#### 隐私政策 URL

你需要准备一个公网可访问的隐私政策页面。

建议最少包含：

- 你是谁
- 收集什么数据
- 为什么收集
- 怎么保存
- 是否共享给第三方
- 联系方式

#### App Privacy

Apple 现在要求你在 App Store Connect 里说明数据处理方式，而且新 App 和更新都要填。

你要按真实情况回答：

- 你是否收集数据
- 收集哪些数据
- 是否用于跟踪
- 是否关联到用户
- 是否包含第三方 SDK 的数据收集

如果你集成了第三方 SDK，也要把第三方的收集行为算进去。

### 7.4 年龄分级

你要在 App Store Connect 里做问卷，系统会给出年龄分级。

重点记住两件事：

- 年龄分级是必填。
- `Unrated` 不能上架到 App Store。

### 7.5 审核信息

如果你的 App 需要登录，Apple 官方审核指南明确要求你提供：

- 可用的审核账号
- 密码
- 特殊配置说明
- 必要时的视频说明或演示模式

如果不提供，审核经常直接卡住或被退回。

## 8. 阶段五：上传 build

第一次上架，最稳的是用 Xcode 上传。

### 8.1 Archive

在 Xcode 里：

1. 选 `Any Mac` 或你的正式构建目标。
2. 用 `Release` 配置做 Archive。
3. 打开 Organizer。

### 8.2 上传到 App Store Connect

在 Organizer 里：

1. 选中归档。
2. 点 `Distribute App`。
3. 选择 `App Store Connect`。
4. 按向导继续。
5. 上传完成后，等 App Store Connect 处理 build。

如果你以后做自动化，也可以用 Transporter。但第一次不建议增加复杂度。

### 8.3 上传后检查

上传成功不等于可提交。

你要在 App Store Connect 里确认：

- build 已经处理完成
- 能被版本页选中
- 版本号 / build 号正确
- 没有明显的签名或能力错误

## 9. 阶段六：提审

### 9.1 选择 build

到 macOS 平台版本页：

1. 选中你刚上传的 build。
2. 检查版本号。
3. 检查导出的符号和崩溃相关设置是否正常。

### 9.2 把所有必填项补齐

提审前逐项确认：

- 截图已上传
- 描述已填
- 关键词已填
- 支持链接可打开
- 隐私政策可打开
- App Privacy 已发布
- 年龄分级已完成
- 分类已选
- 审核联系人信息完整
- 审核备注完整

### 9.3 审核备注怎么写

审核备注不要写空话，直接写 reviewer 真需要的信息：

- App 的核心功能是什么
- 从哪里进入关键功能
- 需要什么权限
- 如果有登录，怎么登录
- 如果某个功能需要特定条件，怎么复现
- 如果菜单栏 App 没有传统主窗口，怎么找到入口

对于这个项目，审核备注里建议明确写出：

- 这是一个 macOS 菜单栏应用
- 主入口在菜单栏右上角状态图标
- 核心功能是多账号切换和配额查看
- 如果需要访问本地 Codex 配置、日志或认证文件，应说明用途

### 9.4 选择发布时间

一般有三种：

- 审核通过后自动发布
- 审核通过后手动发布
- 指定日期自动发布

第一次发版，我建议你选 **审核通过后手动发布**。

原因：

- 你可以最后再检查一遍产品页。
- 可以等官网、隐私页、支持页全部上线后再放出。
- 如果 Apple 在审核留言里补充了提醒，你有余地处理。

## 10. 阶段七：审核后

Apple 官方说明里提到，当前平均有很大比例的提交在 24 小时内完成审核，但这不是保证。

通过后你需要做的事：

- 确认发布策略
- 核对商店页面
- 自己下载一次商店版
- 看沙盒版是否和本地开发版行为一致
- 检查日志路径、权限弹窗、文件访问是否正常

注意：

- 即使审核通过，App 出现在所有 storefront 也可能不是秒级完成。
- Apple 也提到未来发布日期和全球上架存在传播延迟。

## 11. 第一次发布最容易踩的坑

### 11.1 没开 App Sandbox

这对 Mac App Store 是硬伤。

### 11.2 隐私政策是空页面或临时页面

审核很讨厌占位内容。链接必须能打开，而且内容得像真的。

### 11.3 登录功能不给审核账号

如果 reviewer 进不去核心功能，基本等于白提。

### 11.4 菜单栏 App 没写清楚入口

这个项目是菜单栏应用，不像普通 App 一打开就看到主窗口。审核备注里必须明确告诉 Apple：

- 图标在哪里
- 点开后能看到什么
- 如何进入主要功能

### 11.5 本地调试能跑，商店版不行

这是 macOS App 很常见的问题，尤其是：

- 文件路径依赖
- 权限依赖
- Shell / 可执行文件路径依赖
- 用户目录写入
- 沙盒限制

如果你的 App 需要直接访问 `~/.codex/`、外部命令、日志目录或其他本地路径，务必提前验证 App Sandbox 下还能不能工作。这个项目从功能上看，**这会是你上架前最需要实际验证的风险点之一**。

## 12. 针对这个项目，我建议你的上架顺序

### 第一步：先做工程能力收口

优先处理：

- 增加 `.entitlements`
- 开启 App Sandbox
- 确认必要权限
- 检查菜单栏 App 在沙盒下能否工作

### 第二步：把 Bundle ID、名称、图标定死

别等传完 build 再改。

### 第三步：补产品页材料

至少一次性准备：

- 中英文名称
- 副标题
- 描述
- 截图
- 隐私政策
- 支持页

### 第四步：先传一个内部 build

不要第一包就直接正式提审。

### 第五步：做一次“商店版思维”的自测

重点检查：

- 首次启动
- 权限弹窗
- 菜单栏入口
- 登录/切换账号
- 文件读取
- 错误提示

### 第六步：再提审

## 13. 提审前最终清单

你可以把下面这份当最后核对表：

- [ ] Bundle ID 已确定
- [ ] Version / Build 正确
- [ ] App Icon 完整
- [ ] 开启 App Sandbox
- [ ] entitlements 已配置
- [ ] 本地 Archive 成功
- [ ] 上传 build 成功
- [ ] App 名称 / 副标题 / 描述 / 关键词已填
- [ ] macOS 截图已传
- [ ] Privacy Policy URL 可访问
- [ ] App Privacy 已填写并发布
- [ ] 年龄分级已完成
- [ ] 审核联系人信息完整
- [ ] 审核备注说明清楚菜单栏入口和核心流程
- [ ] 如果需要登录，提供审核账号或 demo mode
- [ ] 支持页可访问
- [ ] 自己下载并试过沙盒或发布形态

## 14. 我建议你接下来怎么做

如果你要按最少返工的方式推进，我建议顺序是：

1. 先让我帮你给这个项目补上 `entitlements` 和 App Sandbox。
2. 我再帮你出一版 App Store 文案草稿：
   - 名称
   - 副标题
   - 描述
   - 关键词
   - 审核备注
3. 然后你准备隐私政策页和支持页。
4. 最后我们再一起把提审前 checklist 过一遍。

## 15. 官方参考链接

以下都是 Apple 官方资料：

- 准备分发你的 App：
  - https://developer.apple.com/cn/documentation/xcode/preparing_your_app_for_distribution/
- App Store Connect 总入口：
  - https://developer.apple.com/help/app-store-connect/
- App Information：
  - https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- App Privacy 管理：
  - https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- App Privacy 说明：
  - https://developer.apple.com/app-store/app-privacy-details/
- 截图规格：
  - https://developer.apple.com/cn/help/app-store-connect/reference/screenshot-specifications
- 设置价格：
  - https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price
- 设置年龄分级：
  - https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating
- App Review 说明：
  - https://developer.apple.com/app-store/review/
- App Review Guidelines：
  - https://developer.apple.com/app-store/review/guidelines
- App Sandbox 词条：
  - https://developer.apple.com/help/glossary/app-sandbox/

---

如果你愿意，下一步我可以直接继续做两件具体事：

1. 给这个项目补一份适合上 Mac App Store 的 entitlements。
2. 按这个 App 的真实功能，直接写出可提交的 App Store 文案和审核备注。
