# KikiTalk Apple 登录

> **目录迁移（2026-10-22）：** 当前用户端为 `ios/KikiTalk`，管理端为 `ios/KikiVoiceOps`，均按 Sources/App、Core、Features 与 Tests/Resources/Configuration 组织；原 application/RTCube 和 experiments/livekit/admin-ios 路径只用于识别历史。可点源码链接已映射新位置，旧构建命令和验收仍按原批次阅读。本次未修改正式协议、后端或线上环境。

> **当前入口（2026-10-22）：** 用户 App 为 `ios/KikiTalk/KikiTalk.xcworkspace` / KikiTalk，依赖 SPM LiveKit，已移除腾讯 iOS 组件及示例。下文 2026-10-17 发布、云端清理与验收条目为归档记录；本次仅清理 iOS，不更改账号后端、Apple 配置或正式协议。整体说明见[接手指南](PROJECT_HANDOVER.zh-CN.md)。


## 当前方案

当前版本仅使用 iOS 原生“通过 Apple 登录”。ID 输入、设备随机凭据登录和旧账号迁移已经移除；旧安装包不能继续使用 `/v1/auth/id`。业务账号 ID 与语聊媒体身份由服务器生成，不是可输入的登录凭据。当前账号服务返回账号会话，语聊会话和房间凭证通过独立接口取得。Apple 的 `sub` 不公开展示，不按昵称或邮箱合并账号。

用户先明确同意协议与已满 18 周岁声明，然后通过系统授权；服务器验证授权后建立账号，首次必须设置昵称。应用不请求 Apple 姓名、邮箱，不收取 Apple 密码。成年声明不等于真实年龄核验。退出登录不删除账号，再次通过同一 Apple 账户登录可访问对应资料；注销后重建账号使用新的业务身份。

## 授权与安全

1. `POST /v1/auth/apple/challenge` 返回 `{challengeID,nonce,expiresAt}`，挑战有效 5 分钟。
2. iOS 将挑战原文的 SHA-256 小写十六进制摘要放入系统请求 `nonce`，将 `challengeID` 放入 `state`。这是本项目约定，Apple 不会自动替应用执行该摘要。
3. 系统回调校验 state，随后向 `POST /v1/auth/apple` 发送 `{challengeID,identityToken,authorizationCode,legalConsent}`。
4. 服务端原子消耗挑战，使用固定 Apple JWKS 地址验证 RS256 签名、issuer、Bundle ID audience、时间、subject 和 nonce；再向 Apple 交换一次性授权码并核对返回身份。客户端自行填写的用户标识不能决定登录账号。
5. 账号登录返回 `{token,user}`，再通过账号服务换取独立语聊授权，连接自建 LiveKit；不再签发腾讯 UserSig。业务令牌仅存摘要；Apple 刷新令牌使用独立 Fernet 密钥加密。Apple 私钥只在服务器签发短期 client secret，不进入 App。

取消、缺少凭据、挑战过期或校验失败均不能创建账号。旧授权控制器的迟到回调不会结束新的授权请求；撤回隐私或退出后，旧异步任务不能重新登录。

冷启动、回到前台和重连检查 Apple credential state；撤销时停止媒体和悬浮球，并向 `/v1/auth/apple/revoked` 失效服务端会话。离线失败保留仅用于结束授权的重试凭据；服务端 grant generation 防止旧请求撤销新授权。服务端在刷新路径距上次核验至少 24 小时时，按需向 Apple 核验刷新令牌；不主动轮询未使用账号；网络故障与真正授权失效分别处理。

## 服务端配置

当前 App：`com.kikitalk.demo`；Team ID：`A82X46N3WS`；Key ID：`6NH7S6KJ92`。

仅在受限环境文件 `/etc/kikitalk/server.env` 设置：

```text
APPLE_CLIENT_ID=com.kikitalk.demo
APPLE_TEAM_ID=A82X46N3WS
APPLE_KEY_ID=6NH7S6KJ92
APPLE_PRIVATE_KEY_PATH=/etc/kikitalk/apple/AuthKey_6NH7S6KJ92.p8
APPLE_TOKEN_ENCRYPTION_KEY=<独立生成的 Fernet 密钥>
```

`.p8` 由服务用户读取，权限 0600，父目录 root:kikitalk 0750；环境文件 root:root 0600，由 systemd 载入。配置缺失、私钥格式或权限错误、加密密钥无效时拒绝启动。加密密钥需随数据库做受限备份，不能直接替换后继续读取旧密文；轮换时需迁移尚存的加密刷新令牌和待撤销任务。

Apple 后台还可在对应 App ID 的 Sign in with Apple 配置中添加服务器通知地址：

```text
https://kiki.group/v1/auth/apple/notifications
```

接口只接受 Apple 签名通知并校验 audience、事件时间及去重记录。通知处理 consent-revoked / account-deleted 等事件，已实现接口不代表开发者后台已配置此 URL。原生 iOS 本次不需要 Services ID、网页回调或额外 DNS 记录。

## 注销与数据

账号注销先删除在线业务账号及可删除关联数据，再由后台撤销 Apple 授权；Apple 故障不应阻塞本地账号删除。仅保留撤销所需的加密令牌与重试元数据，成功即删，最长 7 天、最多 180 次，未完成需根据服务日志处理，不能声称第三方故障时已经撤销成功。

**2026-10-17 归档记录：** 旧 ID 用户清理由运维在停止旧服务后执行，在线数据库和头像重新初始化；旧用户和房间标识清单仅存服务器受限备份，供后续腾讯云清理。历史备份保留用于本次变更恢复，不会导入新 Apple 账号。腾讯云账号和云房间需管理员权限，删除在线业务库不等于腾讯云或历史备份即时全部销毁。

正式协议以 `legal/documents.json` 与服务器当前正文为准，客户端校验版本与全文 hash；正文不匹配时需要重新确认。历史 `2026-10-17-r2` 及更早网页保留原文，本次 iOS 清理不修改协议。

## 验证与人工验收

```bash
backend/.venv/bin/python -m pytest -q backend/tests
python3 tools/build_legal_documents.py --check
xcodebuild -workspace ios/KikiTalk/KikiTalk.xcworkspace -scheme KikiTalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

自动化测试使用独立本地签名密钥和 HTTP mock；生产没有测试身份后门。公共真实 challenge 测试可以运行，且不会创建用户。签名构建、单元测试和可访问的 challenge 都不能替代真实 Apple 授权：最终需在已登录 Apple 账户的真机中，点击原生按钮完成一次授权，验证首次昵称、重新登录、注销和 Apple 设置中撤销授权。无需向开发者提供 Apple 密码或验证码。

## 归档：Apple 登录首版发布与保存记录（2026-10-17）

- 修改前Git快照：`codex/backup-before-apple-20261017-115200`，提交 `3e0dca55a03732d8deaf181cb357919467dbba75`；补丁与状态保存在 `~/.local/share/kikitalk/backups/before-apple-20261017-115200/`。工作区原有修改完整保留。
- 服务器预备份：`/var/backups/kikitalk/kikitalk-20261017T035313573121Z/`；旧应用/配置快照 `/var/backups/kikitalk/before-apple-config-20261017T035424Z/`。
- 切换恢复副本：`/var/backups/kikitalk/apple-cutover-20261017T040953Z/`。含5个旧账号、23条旧房间记录及关联历史/头像、旧程序/venv、受限配置和 `retired-cloud-cleanup.json`；服务器备份名时间均为UTC。
- 当前网页发布目录：`/var/www/kikitalk/releases/apple-20261017T040953Z/`。当前在线业务库已清空旧用户和房间，完整性检查通过，服务active。腾讯云侧尚无已配置管理员，不执行无权限的云用户/房间删除；清单留待权限开通后逐项处理。
- 后端103项自动测试通过；iOS39项执行（1项可选实网测试默认跳过），随后额外实际执行该实网challenge测试1项通过。公网伪造凭据、旧ID端点、重复challenge、缺协议与通知签名拒绝均验证。
- `/tmp/KikiTalk-apple-login.xcarchive` 已完成Apple Development签名，App和描述文件均包含 `com.apple.developer.applesignin=[Default]`；11份隐私清单，r2资源hash `a599d544a52bcb8c426a299b9dd6443928b476b31a5f6a607febabaa465db1af`，无.p8私钥。已安装至连接的iPhone「穷奇」。这是开发签名，尚未上传App Store。
- 服务器可访问Apple JWKS；使用无效授权码的连通性预检得到 `invalid_grant`。该预检本身不等于真实个人授权成功。随后用户已在真机完成系统授权并进入昵称页；服务端核对1个Apple身份、1个业务会话、1条加密刷新令牌与当前协议同意记录，昵称也已完成保存。首次真实授权、服务端兑换及建账验证通过；退出重登、注销和系统撤销的完整人工场景仍需分别验收。Apple后台通知URL与腾讯管理员仍待配置。

## 官方资料

- [Apple nonce](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce)
- [验证用户](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [授权码与刷新令牌](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [注销与撤销授权 TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
- [Apple 账号变更通知](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)
- [腾讯云删除账号](https://cloud.tencent.com/document/product/269/36443)
- [腾讯云 App 管理员](https://cloud.tencent.com/document/product/269/31999)
- [腾讯云解散房间](https://cloud.tencent.com/document/product/454/124184)
