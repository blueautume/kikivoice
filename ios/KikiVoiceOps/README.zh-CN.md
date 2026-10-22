# Kiki 运维 iOS

独立 SwiftUI 管理 App，提供两个只读看板及另行授权的社区管理，Bundle ID `com.kikitalk.voiceops`，最低 iOS 17，开发 Team `A82X46N3WS`。打开 `KikiVoiceOps.xcworkspace` 并选择共享 scheme `KikiVoiceOps`；不依赖腾讯、LiveKit SDK 或第三方网络库。普通 KikiTalk 的 Apple 登录保持原状，运维身份另建独立命名空间。

P0 新增 `community` 独立权限：查看举报、警告、临时禁言／禁麦、语聊封禁、关房与解除限制。查看权限不能代替社区权限，语聊限制不封禁 Apple 账号；所有处置需说明理由和二次确认。未知处理结果先保存在按账号隔离的 Keychain 中，关闭页面、后台或重启后使用同一请求编号恢复，确认后删除，避免网络超时重复处罚。详细范围和验收见 [P0 交付说明](../../docs/P0_COMMUNITY_SAFETY.zh-CN.md)。

## 工程结构

2026-10-22 已从原 `experiments/livekit/admin-ios` 迁至 `ios/KikiVoiceOps`，工程/Bundle ID/系统凭据命名空间保持独立。入口及跨App说明见[iOS导航](../README.md)。

| 位置 | 职责 |
| --- | --- |
| `Sources/App/` | KikiVoiceOpsApp、OpsStore与生命周期 |
| `Sources/Core/Networking/` | OpsIdentityAPI、OpsTransport |
| `Sources/Core/Security/` | PasskeyAuthorization、SessionVault |
| `Sources/Core/Models/OpsServiceModels.swift` | 服务、权限、端点与会话模型（原VoiceService） |
| `Sources/Features/Dashboard/` | 账号/语聊看板模型和界面 |
| `Sources/Features/Community/`、`Diagnostics/` | 社区治理、房间技术问题 |
| `Tests/` | Authentication/Dashboard/Community/Diagnostics/Integration；Fixtures中的JSON作为测试资源 |
| `Resources/` | Assets、PrivacyInfo.xcprivacy |
| `Configuration/` | Info.plist、KikiVoiceOps.entitlements |
| `Scripts/` | 工程与图标生成器 |

以下登录/服务规则不因目录移动改变。历史验证结果仅代表其记录日期，本轮移动不重做公网验收。

## 通行密钥登录

使用系统 `ASAuthorizationPlatformPublicKeyCredentialProvider` 创建或发现式登录通行密钥，RP ID 为 `kiki.group`。系统管理私钥和生物识别，App 只向服务器提交原始 WebAuthn clientDataJSON、attestationObject 或 authenticatorData/signature/userHandle 的无 padding Base64URL。服务器校验挑战、签名、RP、origin 和用户验证，不在客户端模拟授权成功。

首次创建后必须填写自己的名字（NFC、1–32 字、不含控制字符）。名字允许相同，`ops_` 唯一编号不可变。**所有新账户，包括第一个账户，都没有任何服务权限**；需将名字与唯一编号提供给管理员，由服务器单独授予账号、语聊的只读权限。客户端没有授权接口、默认管理员、名字找回或口令回退。

已同步到 iCloud 钥匙串的通行密钥可在其他设备登录。新增凭证、凭证删除和账户恢复本期未提供；丢失通行密钥后新建的身份仍需重新核验与授权，不能仅凭同名继承权限。

登录和命名页均提供[运维账户隐私说明](https://kiki.group/ops/privacy/)。应用声明收集运维唯一编号和名字用于应用功能，不跟踪用户，不收集 Face ID/Touch ID 生物识别数据或通行密钥私钥。

## Associated Domains 与真机签名

App entitlement 为 `webcredentials:kiki.group`，Xcode target 已开启 Associated Domains capability。服务器 AASA 的 `webcredentials.apps` 应包含：

```text
A82X46N3WS.com.kikitalk.voiceops
```

AASA 位于 `https://kiki.group/.well-known/apple-app-site-association`，使用受信任 HTTPS 且不重定向。真机开发签名的 App ID/描述文件必须包含该 capability；Apple CDN 缓存传播可能影响首次安装。配置依据 [Apple Supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys)、[Supporting associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains) 和[官方连接示例](https://developer.apple.com/documentation/authenticationservices/connecting-to-a-service-with-passkeys)。

系统授权期间 `scenePhase.inactive` 仅暂停轮询并遮盖画面，避免把 Face ID/系统通行密钥页误当后台取消；真正进入 background 时取消授权 controller、注册/登录请求和刷新，并隔离迟到结果。真实系统通行密钥创建、选择和 Face ID 确认需由用户最后手动操作。

## 统一会话与服务边界

所有认证、`me`、命名及看板网络请求固定发送到 **`https://kiki.group/admin/v2`** 精确路径；App 不直接请求 `furby.top` 管理 API。语聊看板通过服务器间签名聚合，仍显示真实数据来源 `furby.top`，账号看板显示 `kiki.group`；两种 schema、指标和 ACL 分开。

- `POST /admin/v2/auth/registration/options` 与 `/verify`：创建通行密钥身份。
- `POST /admin/v2/auth/authentication/options` 与 `/verify`：发现式登录。
- `GET/PATCH /admin/v2/me`：重新确认身份与 ACL、设置名字。
- `DELETE /admin/v2/auth/session`：退出统一会话。
- `GET /admin/v2/services/account/dashboard`、`/voice/dashboard`：各自只读看板。

短期 opaque 会话最长 8 小时，仅存放于本机 `com.kikitalk.voiceops.identity.v2` Keychain service，使用 `WhenUnlockedThisDeviceOnly`、不跨设备同步。通行密钥由系统另外同步。启动时按精确 namespace 删除旧 `admin.voice.v1`、`admin.account.v1` 口令时代的会话，不读取、不迁入、不使用它们。

URLSession 使用 ephemeral/no-store/no-cookie；拒绝所有重定向、HTTP、自定义端口、查询参数、非白名单路径及错误方法。认证 options/verify 不携带已有 Bearer，统一管理凭证不发送到普通业务 API、语聊服务器或其他域名；不会在日志、scheme 或偏好设置保存凭证。

每次恢复前台、切换服务和刷新，先向服务器获取 `me` 当前 ACL，再决定是否读取看板。未命名或缺少对应权限时不请求该看板，只显示名字、唯一编号和待授权状态。403 清空被拒绝的数据并重新读取 ACL，保留登录及另一服务权限；401/到期/退出清空统一凭证和所有快照。退出、切后台、切服务后的迟到响应不能恢复旧数据。只有看板获取失败且未收到撤权结果时，才保留上次数据与时间并标记错误。

精确协议见 [`../../experiments/livekit/shared/ops-passkey-contract.json`](../../experiments/livekit/shared/ops-passkey-contract.json)。普通 Apple 业务会话、旧管理口令和统一运维会话互不通用。

## 只读看板

| 服务 | 运营与运维数据 |
| --- | --- |
| 语聊 · furby.top | 活动房间、SFU 实际在线、入场名额、今日创建/结束、语聊参与身份、麦位；语聊主机 CPU/内存/磁盘/网络、证书与服务健康、连接/音频质量聚合和告警 |
| 账号 · kiki.group | 总账号/今日新建、有效业务会话及关联账号、Apple 授权和待撤销队列、头像与数据库占用；账号主机 CPU/内存/磁盘/网络、证书/API 健康和告警 |

“语聊参与身份”和“有效业务会话”均不代表真实用户 DAU 或实际在线。入场名额与 SFU 实际连接人数分开。缺失/过期指标显示“未知”；前台每 15 秒刷新，后台暂停。看板不返回普通用户邮箱、Apple subject、私密刷新令牌，不提供控制房间、封禁或重启等操作。

## 验证

离线签名回归使用独立随机 Keychain namespace，覆盖 URL/方法 allowlist、重定向、WebAuthn 选项与 Base64URL、原始字段序列化、首次命名、零默认权限、统一会话过期、me/ACL、403/401、inactive 与 background、切服务/退出后的迟到响应。默认不发公网请求，也不会弹系统授权。

```sh
xcodebuild test \
  -workspace KikiVoiceOps.xcworkspace \
  -scheme KikiVoiceOps \
  -destination 'platform=iOS Simulator,id=B1DC4560-BDAF-4264-AE5E-D94B23DB031B' \
  -derivedDataPath /tmp/kiki-ops-passkey-derived \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

2026-10-19 离线签名回归执行 24 项：23 通过、1 个公开测试显式跳过、0 失败；结果为 `/tmp/kiki-ops-passkey-offline.xcresult`。随后 generic iOS device build 使用 `-allowProvisioningUpdates` 成功，签名产物的 App ID 为 `A82X46N3WS.com.kikitalk.voiceops`，Associated Domains 为 `webcredentials:kiki.group`；未运行任何真机。

单个公开测试 `VoiceOpsIntegrationTests/testRealPasskeyIdentityPendingACLAndBothAuthorizedDashboards` 默认跳过。显式启用时由 runner 私密注入 `TEST_RUNNER_KIKI_OPS_PASSKEY_SESSIONS_JSON`，内容为 `{pending:完整sessionResponse, authorized:完整sessionResponse}`；两者均须由服务器真实软件 ES256/WebAuthn 验签产生的临时身份，授权身份只能由管理员显式授予两个 scope。测试核对未授权双锁、403、两个真实来源的运营/运维截图及退出后 401；测试后撤权并清理精确临时身份。

该公开测试只证明服务器验签会话、ACL 和原生看板链路，**不代表已经验证系统通行密钥 UI、iCloud 同步或真实 Face ID**。会话不得写入源码、scheme、附件或终端输出，原始运行日志和 xcresult 应保存在本机受限目录。

新增 Swift 文件后运行 `python3 Scripts/generate_project.py` 重新生成项目。图标的普通、深色和着色版本沿用现有运维图标，修改后可用 `swift Scripts/generate_app_icon.swift` 重新生成。

最终公网签名回归为 24/24 通过、0 跳过、0 失败：`/tmp/kiki-ops-passkey-public.xcresult`。两个明确的临时软件 WebAuthn 验收账号已删除，没有为真人自动授权。5 张待授权/双服务看板截图与完整部署记录见 [运维 Passkey 说明](../../docs/OPS_PASSKEYS.zh-CN.md)。系统 Passkey 与 Face ID / Touch ID 仍需本人完成授权确认。
