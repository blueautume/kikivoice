# KikiTalk 服务端

> **当前切换（2026-10-19）：** 当前工作区已为自建 LiveKit 停机替换接入账号到语聊的授权桥接，以及独立只读账号管理 API。账号服务 `kiki.group`（`43.138.219.160`）继续负责 Apple 登录、资料、协议与注销；语聊媒体/房间由 `furby.top`（`139.224.50.108`）负责。两台主机和业务/语聊/运维凭证保持分离；视频、音效和礼物入口不在本次开放范围。 服务器实际部署、备份、协议及真机待验状态见 [LiveKit 停机切换](../docs/LIVEKIT_CUTOVER.zh-CN.md)。

> **当前运维认证：** Kiki 运维改用由账号服务器 `kiki.group` 统一管理的 Passkey 身份与逐看板 ACL，普通 KikiTalk 的 Apple 登录保持独立。所有新运维身份（包括第一位）默认零权限；设置姓名后仍需在服务器按不可变账号 ID 和当前姓名手动授权。生产两端使用 `ADMIN_AUTH_MODE=passkey`，旧 `/admin/v1` 口令及令牌不能读取管理数据，也没有密码回退。语聊服务器仅接受账号服务器的独立 HMAC 聚合请求，不保存运维账号或权限。配置、授权/撤权命令及本轮真实验收见 [运维 Passkey 说明](../docs/OPS_PASSKEYS.zh-CN.md)。

## P0 社区管理与账号统计增量（2026-10-19）

以下为本次工作区实现，部署和真机验收状态以主切换记录为准。`account`、`voice` 仍分别只允许查看两个服务看板；新增 `community` 独立权限允许查看和处理语聊举报，现有看板观察员不会自动取得它。首次启动会原子升级旧 ACL 表的约束并保留原授权。`GET /admin/v2/me` 的 `account.permissions` 新增 `community` 布尔值；所有新身份仍为三个 `false`。

服务器 CLI 必须由服务用户执行，仍严格同时匹配当前姓名与不可变账号编号。例如 `python -m app.ops_auth grant --account-id <ops_编号> --name <当前姓名> --service community`；撤权改为 `revoke`。没有网络授权接口。改名不转移权限，同名账号不共享权限，禁用/删除身份或撤回权限后立即拒绝后续请求。

| 账号端点 | 请求与行为 |
| --- | --- |
| `POST /admin/v2/services/voice/moderation/query` | 独立 Passkey Bearer + `community`；`{status:"pending"/"resolved"/"all",limit:1..50}`，默认 pending、30 |
| `POST /admin/v2/services/voice/moderation/action` | 同上；`{requestID,reportID,action,durationSeconds?,note}`；requestID为标准UUID，note为1–500字明确处置理由；action 为 warn、mute_chat、mute_audio、ban_user、close_room、dismiss、restore_user。仅三种临时限制必须带60–2592000秒，其它动作不接受时长 |
| `POST /v1/me/activity` | 普通 Apple Bearer 且当前协议同意有效；空 JSON `{}`，仅客户端进入前台调用，返回 `{recorded:true,day:"YYYY-MM-DD",retentionDays:35}`；失败不阻断语聊 |

社区代理只访问 `https://furby.top/internal/admin/v2/moderation/query` 与 `/action`，请求不接受任意 URL、目标用户或 `opsActorID`；后者由已登录 Passkey 的稳定账号编号注入。沿用独立 `OPS_BRIDGE_SECRET`，HMAC 绑定方法、固定路径、时间戳、随机 nonce 与精确请求体 SHA-256；不转发客户端 Bearer，不跟随重定向，响应最多2 MiB、总耗时最多3秒，并在返回前重新核对授权。超时不自动重放操作；客户端使用同一 requestID 查询/重试，由语聊服务幂等提交与记录审计。举报、证据、限制和处理结果均由语聊服务保存；账号服务仅管理运维身份和权限。

`operations.activity` 返回 `trackingSince`（Unix秒）、`activeAccountsToday`、`returningAccountsToday`、7/30天去重活跃、昨日队列回访率与7日日序列。按上海自然日、普通账号和客户端明确前台信号去重；后台续租、有效登录凭证及运维访问不计入。今日回访指前34天有活跃且今日再次活跃，昨日回访率按昨日队列计算。只覆盖更新后的客户端，不补造历史，不能将该数当作实时在线人数。数据库仅保留账号与日期，最长35天，定时清理；注销、Apple撤销通知删除账号时级联删除，撤回协议同意也立即清除对应记录。

隐私同意撤回通过现有耐久授权撤销 outbox 传递 `reason:"withdrawal"`；普通退出仍为默认 logout，不会清空拉黑。原 `voice_revocation_outbox` 自动追加 `reason`、`consent_epoch` 列，按同一 source revoke 事件幂等升级撤回意图，不重复排队。服务端交换同时签入 `consentEpoch`（当前真实同意事件ID）与 `lastWithdrawalEpoch`（最近真实撤回事件ID，无则0）；撤回事件携带自己的单调事件ID。语聊服务在接受新的同意前先清理尚未确认的旧撤回数据，迟到的旧 outbox 仍只撤销旧授权，不能撤回新同意、清除新同意后创建的数据。使用数据库自增事件序列区分同秒撤回和重新同意，不把后台续租当作再次接受条款。仅 Apple credential state 变化不等于隐私协议撤回，继续精确失效业务会话；真实 Apple 签名撤回通知仍按原账号删除流程处理。

公开昵称和简介经过基础本地词表检查，拦截控制/隐藏格式字符，并对大小写、全角、空白和标点做归一化匹配；违规返回422且不回显输入。`PUBLIC_CONTENT_BLOCKLIST` 可按逗号或换行追加字面短语，最多32 KiB，不上传第三方、不记录拒绝内容。它只能减少明显违规文字，不能替代举报、人审、头像检查或实时语音审核。

`maintenance.backup` 只读固定 `/var/lib/kikitalk/backup-status.json` 中的公共汇总：`lastSuccessAt`、`verifiedAt`（Unix秒）、`backupAgeSeconds`、`healthy`（无状态时null）、`retentionDays:7`、安全的 `lastError`。拒绝符号链接、非普通文件、错误服务名和过大内容，不将备份路径或错误堆栈提供给 App。备份/校验超过36小时或任务失败时显示告警。备份与副本恢复脚本由运维统一配置；此接口不会执行恢复，也不声称既有手工历史备份已被清除。

## 历史版本说明

以下保留原腾讯/Apple 版本的部署、API 与测试记录，便于查历史；其中 UserSig、腾讯房间、礼物及旧验收数量不代表本次自建语聊切换结果。现行接口与发布状态以当前源码及上方切换记录为准。

真实账号、腾讯云 UserSig 签发、资料、房间登记、收藏和浏览记录服务。音视频、麦位、成员和房间消息由 iOS 中的腾讯云 SDK 承担。

新增自有免费 GIF 礼物服务：一次性发放一亿体验钻石、服务器定价扣款、UUID 幂等账目及房间礼物动态。无需开通腾讯云商业礼物或支付服务；接口、数据保留、隔离测试和发布记录见 [礼物功能说明](../docs/GIFTS.zh-CN.md)。现有 Apple 登录及旧业务接口保持兼容。

当前 **Apple 登录专用版本**已于2026-10-17部署到生产，旧用户在线数据清理与公网验收完成；本人真机首次Apple授权与服务端兑换已确认成功。完整接入及人工验收步骤见 [Apple 登录说明](../docs/APPLE_LOGIN.zh-CN.md)。

当前业务地址：`https://kiki.group`；官网为 `/`，API 保留 `/v1/`，健康检查为 `/health`。Nginx 提供受信 CA 签发的 HTTPS，反向代理到仅监听 `127.0.0.1:8000` 的 FastAPI。App 和 SDK 头像使用系统 CA、域名及有效期校验，正常续证不再需要发布新 App。旧版固定 IP 安装包需更新。

当前域名证书有效期至北京时间 **2027 年 1 月 14 日 20:59:59**，覆盖 `kiki.group` 与 `www.kiki.group`；本次使用提供的证书，尚未配置自动签发续期。私钥只存于服务器 `/etc/nginx/tls/kiki.group/privkey.pem`（root:root、0600）和本机 `~/.config/kikitalk/tls/kiki.group/`（目录0700、文件0600），不进入仓库和 App。完整部署、续证和回滚说明见 `docs/DOMAIN_DEPLOYMENT.zh-CN.md`。

## 部署和维护

服务器使用独立的 `kikitalk` 系统用户运行服务，systemd 自动启动和异常重启。部署文件在 `/opt/kikitalk`，SQLite 在 `/var/lib/kikitalk/kikitalk.sqlite3`，头像在 `/var/lib/kikitalk/avatars`（目录 `0700`、文件 `0600`），凭据在 `/etc/kikitalk/server.env`，只有 root 能读取环境配置文件。原有服务器管理面板及 SSH 服务不受此服务控制。

本机 SSH 私钥放在 `~/.ssh/kikitalk_server.pem`（权限 `0600`），服务器主机公钥固定在 `~/.ssh/kikitalk_known_hosts`。腾讯云凭据仅保存在本机 `~/.config/kikitalk/server.env`（权限 `0600`）和服务器环境文件中。它们不属于仓库和 App 安装包。

```bash
# 更新后端（保留服务器现有凭据和Nginx证书，不删除数据库）
bash backend/deploy/deploy.sh

# 使用系统CA检查公网状态
curl --fail https://kiki.group/health

# 手动创建一致的数据库及头像备份，保存于服务器 /var/backups/kikitalk
bash backend/deploy/backup.sh

# 通过项目配置的 SSH 别名登录后
systemctl status kikitalk
journalctl -u kikitalk --since '10 minutes ago'
```

部署脚本可用 `KIKI_SSH_IDENTITY`、`KIKI_KNOWN_HOSTS` 覆盖SSH配置路径，`KIKI_SERVER_HOST`指定SSH目标。`KIKI_SERVER_ENV`仅在首次服务器无配置文件时使用，普通更新保留现有生产凭据。服务器需 Python 3.11+、openssl、systemd、Nginx，公网开放80/443；8000仅回环监听。更换服务器时更新DNS及新机证书/数据，App继续访问域名。Nginx覆盖转发来源头，Uvicorn只信任127.0.0.1提供的代理头，保持按真实来源IP限流。

Apple 版本首次部署前，须在服务器受限环境文件中补齐以下配置；部署脚本不会自动覆盖已有 `server.env`，也不会上传 `.p8`：

```text
APPLE_CLIENT_ID=com.kikitalk.demo
APPLE_TEAM_ID=A82X46N3WS
APPLE_KEY_ID=6NH7S6KJ92
APPLE_PRIVATE_KEY_PATH=/etc/kikitalk/apple/AuthKey_6NH7S6KJ92.p8
APPLE_TOKEN_ENCRYPTION_KEY=<独立生成并受限备份的 Fernet 密钥>
```

`.p8` 供 `kikitalk` 服务用户读取，文件权限 `0600`，父目录 `root:kikitalk`、`0750`；环境文件仍为 `root:root`、`0600`，由 systemd 载入。Apple 配置缺失、私钥格式或权限不符、令牌加密密钥无效时拒绝启动。私钥及加密密钥均不得进入 App、源码包或 Git。数据库含加密刷新令牌，须另行受限备份对应加密密钥；备份脚本只复制数据库及头像，不会备份这些密钥。轮换加密密钥时需迁移存量密文及待撤销任务，不能直接替换配置。

备份脚本在 SQLite 写锁内复制数据库和当前被引用的头像，生成包含 `kikitalk.sqlite3`、`avatars/` 的时间戳目录；读取服务保持可用，写操作短暂等待。旧版只有 `.sqlite3` 的备份不包含头像。恢复时先停止服务，将同一份备份的数据库及头像目录一并复制回原路径，恢复 `kikitalk:kikitalk` 所有者、数据库/图片 `0600`、头像目录 `0700`，移除同名旧 `-wal`/`-shm` 后启动服务。不要在服务运行时直接覆盖 SQLite 文件。脚本按当前正式环境默认数据路径备份；如设置自定义目录，需同时调整备份源路径。

## 账号与身份

当前仅允许 iOS 原生 Sign in with Apple。旧 ID 输入、`deviceSecret` 设备绑定登录和 `/v1/auth/id` 已从当前应用及认证路径移除，不兼容或合并旧内测账号。切换时旧用户及关联在线数据由运维按授权清理，服务本身不会在每次启动时自动删库。旧数据库备份及腾讯云侧清理另行记录，不能用业务库清空代表全部云端数据已删除。

登录先取得服务端一次性挑战，有效期 5 分钟。iOS 将挑战原文的 SHA-256 小写十六进制摘要用作 Apple 请求的 `nonce`，将 `challengeID` 用作 `state`，校验系统回调后提交身份令牌、一次性授权码和协议同意。服务端原子消耗挑战，使用固定 Apple JWKS 地址校验 RS256 签名、issuer、Bundle ID audience、时间、subject、nonce，随后向 Apple 兑换授权码并再次核对身份；存在 `c_hash` 时校验授权码绑定。不采用客户端自行声明的用户标识，不按邮箱或昵称合并账号。

`identities.provider=apple` 保存已验证的 Apple `sub`，不作为公开资料或腾讯 SDK 用户 ID。业务展示 ID 与 SDK 身份由服务端生成。首次登录必须设置 1–16 字昵称；`needsNickname=true` 时拒绝创建房间、标记开播和记录进入房间，返回 `409`，提交合法 `PATCH /v1/me` 的 `name` 后解除。应用不请求 Apple 姓名、邮箱，也不接收 Apple 密码；Apple 身份令牌和访问令牌仅用于校验，不持久化。所需刷新令牌使用独立 Fernet 密钥加密保存。

Bearer 会话使用 256 位随机值，数据库只存 SHA256 哈希，有效期 30 天，已登录客户端刷新时顺延。UserSig 服务端签发，有效期 24 小时；腾讯云 SecretKey 从不发给客户端。`/v1/auth/refresh` 在距上次 Apple 核验至少 24 小时时验证刷新令牌；未调用刷新路径时不会主动每日轮询 Apple。iOS 在冷启动、回前台及重连时另行检查系统 credential state。退出登录只撤销当前业务会话；客户端报告当前 Apple 授权失效时撤销账号全部业务会话，旧授权代重试只清理其旧代会话，不会撤销后续重新授权产生的新会话。

注销先删除全部业务会话、身份绑定、资料和个人资料库，并结束、匿名化旧房间登记，再由后台申请撤销 Apple 授权。Apple 暂时故障不阻塞本地删除，仅保留所需加密刷新令牌和重试元数据，成功即删，最长 7 天、最多 180 次；到期未完成会写错误记录并清除队列凭据，不能据此声称 Apple 端已成功撤销。再次 Apple 登录会建立新的业务和腾讯云身份，不能恢复已注销资料。

`POST /v1/auth/apple/notifications` 只接受 Apple 签名通知，核对 audience、时间及事件并幂等去重；`consent-revoked`、`account-deleted` 会清理对应业务账号。短期事件摘要防止撤销通知先于登录提交或延迟到达时错误建账、误删新授权。需由开发者在 Apple 后台为 App ID 填写 `https://kiki.group/v1/auth/apple/notifications`；实现接口不代表后台配置已完成。原生 iOS 本次不需要 Services ID、网页回调或额外 DNS。

## API 合约

当前仅面向18周岁及以上用户。Apple登录必须携带 `legalConsent={privacyVersion,termsVersion,documentHash,accepted:true,adultConfirmed:true}`，版本和SHA-256来自与App/官网同源的 `app/legal_documents.json`；当前工作区版本为 `2026-10-17-r2`，缺少或版本不符返回428及 `requiredVersions`。启动时验证正式文本与哈希，禁止用旧用户记录自动推定同意。仍有效的 Apple 业务会话需先通过 `POST /v1/me/legal-consent` 确认当前协议，才能刷新SDK凭据和访问普通业务；退出、注销及协议状态操作保留。旧 ID 会话不能通过补签恢复使用。

`legal_consent_events` 记录账号、版本、文本哈希、同意/撤回、18+声明和服务器时间，不采集手写签名或出生日期。撤回撤销该账号全部业务会话，当前请求旧令牌摘要可在24小时内仅用于同一DELETE的幂等结果确认，不会再次撤回重新登录后的新会话；启动、后续撤回及运行中定期清理过期摘要，注销级联删除。已经签发的腾讯UserSig有其独立有效期，不能把业务会话删除描述成服务端即时撤销所有腾讯凭据；App会停止本机采集并退出SDK。

除健康检查、Apple challenge/登录、Apple 签名通知和公共头像读取外，端点需要 `Authorization: Bearer <token>`。通知使用签名校验而非业务 Bearer。时间均为 Unix 秒；历史排序内部使用纳秒防止同一秒多次浏览排序不稳定。错误统一返回 `{ "detail": "中文说明" }`，敏感参数和 bearer 不写入访问日志。JSON 等普通请求体最多 16 KiB；仅 `POST /v1/me/avatar` 的二进制头像上传允许最多 2 MiB，分块请求同样受限。额外 JSON 字段会被拒绝。

| 方法及路径 | 输入 | 输出 |
| --- | --- | --- |
| `GET /health` | 无 | `{status:"ok", rtcConfigured:true}` |
| `POST /v1/auth/apple/challenge` | `{}`，无需 Bearer | `{challengeID,nonce,expiresAt}`，5 分钟有效 |
| `POST /v1/auth/apple` | `{challengeID,identityToken,authorizationCode,legalConsent}`，无需 Bearer | `{token,user,sdk}` |
| `POST /v1/auth/apple/notifications` | `{payload:<Apple签名JWT>}`，无需 Bearer | `{ok:true}`，校验签名、事件及去重后处理 |
| `POST /v1/auth/apple/revoked` | 无请求体，需 Bearer | `{ok:true}`，当前授权失效时撤销账号全部会话，旧授权重试仅清其旧代；不以客户端状态直接删除账号 |
| `GET /v1/me/legal-consent` | 无 | `{requiredVersions,legalConsent,requiresAcceptance}`，同意时间为服务器Unix秒 |
| `POST /v1/me/legal-consent` | `{legalConsent:{privacyVersion,termsVersion,documentHash,accepted:true,adultConfirmed:true}}` | 同上，相同有效版本幂等返回 |
| `DELETE /v1/me/legal-consent` | 无 | `{ok:true}`，撤回并撤销该账号全部业务会话 |
| `POST /v1/auth/refresh` | 无 | `{user,sdk}`，按需核验 Apple 授权，保留同一 token 并延长会话 |
| `POST /v1/auth/logout` | 无 | `{ok:true}` |
| `GET /v1/me` | 无 | User |
| `PATCH /v1/me` | 可选 `{name,bio,avatarIndex,notificationsEnabled}` | User |
| `POST /v1/me/avatar` | 原始 JPEG 二进制，`Content-Type: image/jpeg`，最多 2 MiB | 更新后的 User |
| `GET /v1/avatars/{64位随机十六进制}.jpg` | 无需认证，只读 | `image/jpeg` |
| `DELETE /v1/account` | 无 | `{ok:true}`，在线业务数据先删除，Apple 撤销失败转后台队列 |
| `GET /v1/rooms` | 无 | `{rooms:[Room]}`，最近 500 条登记 |
| `POST /v1/rooms/lookup` | `{ids:[String]}`，每批最多 100 个 ID | `{rooms:[Room]}`，按输入顺序去重，仅返回存在的登记 |
| `POST /v1/rooms` | `{title,category,isLive,theme}` | Room，初始 `draft` |
| `GET /v1/rooms/{id}` | 无 | Room |
| `PATCH /v1/rooms/{id}` | `{status:"draft"/"live"/"ended"}` | Room，仅房主可操作，结束后不可重开 |
| `GET /v1/library` | 无 | `{favorites:[Room],recents:[Room],created:[Room]}` |
| `PUT /v1/favorites/{id}` | 无 | `{ok:true}`，登记不存在时 404 |
| `DELETE /v1/favorites/{id}` | 无 | `{ok:true}` |
| `POST /v1/history/{id}` | 无 | `{ok:true}`，去重保留最近 20 条 |

`User = {id, sdkUserID, name, bio, avatarIndex, avatarURL, needsNickname, notificationsEnabled}`。`avatarURL` 为绝对 HTTPS URL 或 `null`；`needsNickname` 为是否必须完成昵称设置。昵称 1–16 字，简介最多 80 字，支持多行并将 CRLF/CR 换行统一为 LF，其他控制字符不允许，头像索引 0–11。

头像上传由 Pillow 验证实际 JPEG 格式并完整解码；原图至少 64×64、单边最多 8192、最多 2000 万像素。服务端按 EXIF 方向旋正，居中裁剪为 512×512，重新编码为 JPEG 并清除 EXIF/ICC 等元数据。只允许服务端生成的 64 位随机十六进制文件名，不能通过请求指定路径。公共头像可用于房间展示，请勿上传私密图片；公共读取沿用 HTTPS 和 `nosniff`，不需要将 Bearer 交给 SDK。头像替换、`avatarIndex` 切回预设及账号注销都会清理旧图；房主资料变更同步到已有房间登记。未认证上传返回 `401`，错误 Content-Type/图片格式返回 `415`，损坏或尺寸不符返回 `422`，超过上限返回 `413`。

头像存储目录默认是数据库同级的 `avatars/`，可通过 `AVATAR_DIRECTORY` 配置；URL 前缀通过 `PUBLIC_BASE_URL` 配置，当前为 `https://kiki.group`。URL按配置生成，不信任请求Host或伪造转发头。SDK图片加载器和业务图片请求都沿用系统HTTPS信任，不使用跳过验证或trustedHosts绕过。登录/刷新后会将新域名头像同步到腾讯SDK用户资料。

`sdk = {sdkAppID, userID, userSig, expiresAt}`，其中 `userID` 等于 `User.sdkUserID`。

`Room = {id,title,host,hostID,hostAvatarIndex,hostAvatarURL,audience,isLive,theme,category,isCreatedByMe,status,createdAt}`。`hostAvatarURL` 为房主自选头像绝对 HTTPS URL 或 `null`。`hostID` 为腾讯云 SDK 用户 ID；主题索引 0–5；标题最多 40 字且 UTF-8 编码不超过 100 字节，分类最多 12 字。语聊 ID 前缀为 `voice_kiki_`，直播为 `live_kiki_`。

登记不是在线状态的判定依据。API 不猜测在线人数，`audience` 固定为 0；客户端以腾讯云返回的实际房间列表及累计观看人次合并展示，房内成员由 SDK 实时显示，并按 SDK 在线房间 ID 分批调用 `rooms/lookup` 获取对应元数据，避免历史登记较多时漏掉仍在线的旧房间。收藏和历史保存结束房间以保留真实记录。房主创建 SDK 房间成功后标记 `live`，退出并结束后标记 `ended`；如果客户端异常退出，首页仍依据 SDK 在线列表移除失效房间。

## 验证

```bash
python3 -m venv backend/.venv
backend/.venv/bin/python -m pip install -r backend/requirements-dev.txt
backend/.venv/bin/python -m pytest -q backend/tests
```

Apple登录基线 **103 项测试通过**；新增礼物和QA测试26项也已验证，具体批次及生产验收见 [礼物功能说明](../docs/GIFTS.zh-CN.md)。Apple 专项覆盖一次性/过期/并发 challenge、nonce 与授权码绑定、签名和算法混淆、issuer/audience/时间/subject、JWKS 缓存与轮换节流、加密存储、每日核验、刷新与新登录并发、旧授权撤销重试、通知签名/去重/乱序及先于登录提交、远端故障时本地注销和队列重试/到期。原有资料、头像、昵称、房间、跨账号权限、UserSig、会话、协议同意/撤回和大小/速率限制测试继续通过；旧 ID 端点不存在、旧设备凭据不能登录也有验证。

iOS 本轮 39 项测试执行完成（1 项 opt-in 跳过，其余通过）。自动化使用独立本地签名密钥及 HTTP mock，生产验证器没有测试身份后门。随后额外执行的iOS真实challenge测试通过且未跳过；本人已在真机完成首次真实授权，服务端确认兑换、建账、会话、加密令牌、协议记录及昵称保存正常。退出重登、注销、系统撤销仍需分别人工验收。生产部署、旧用户清理及公网验证已完成，详见 [Apple 登录说明](../docs/APPLE_LOGIN.zh-CN.md)。

UserSig 协议参考腾讯官方实现：[Tencent-RTC/tls-sig-api-v2-python](https://github.com/Tencent-RTC/tls-sig-api-v2-python)。
