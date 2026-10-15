# KikiTalk 服务端

真实账号、腾讯云 UserSig 签发、资料、房间登记、收藏和浏览记录服务。音视频、麦位、成员和房间消息由 iOS 中的腾讯云 SDK 承担。

当前地址：`https://43.138.219.160`。App 固定校验随包附带的服务器证书；使用 HTTPS，不跳过证书校验。公钥证书在 `deploy/server.crt`、`deploy/server.der`，私钥只在服务器的 `/etc/kikitalk/server.key`。证书有效期至北京时间 **2027 年 10 月 16 日 03:11**。换证时需同步更新 App 内的 DER 文件及固定指纹并发布新版本。

## 部署和维护

服务器使用独立的 `kikitalk` 系统用户运行服务，systemd 自动启动和异常重启。部署文件在 `/opt/kikitalk`，SQLite 在 `/var/lib/kikitalk/kikitalk.sqlite3`，头像在 `/var/lib/kikitalk/avatars`（目录 `0700`、文件 `0600`），凭据在 `/etc/kikitalk/server.env`，只有 root 能读取环境配置文件。原有服务器管理面板及 SSH 服务不受此服务控制。

本机 SSH 私钥放在 `~/.ssh/kikitalk_server.pem`（权限 `0600`），服务器主机公钥固定在 `~/.ssh/kikitalk_known_hosts`。腾讯云凭据仅保存在本机 `~/.config/kikitalk/server.env`（权限 `0600`）和服务器环境文件中。它们不属于仓库和 App 安装包。

```bash
# 更新服务（不改变服务器已有证书，不删除数据库）
bash backend/deploy/deploy.sh

# 使用固定证书检查公网状态
curl --cacert backend/deploy/server.crt https://43.138.219.160/health

# 手动创建一致的数据库及头像备份，保存于服务器 /var/backups/kikitalk
bash backend/deploy/backup.sh

# 通过项目配置的 SSH 别名登录后
systemctl status kikitalk
journalctl -u kikitalk --since '10 minutes ago'
```

部署脚本可用 `KIKI_SSH_IDENTITY`、`KIKI_KNOWN_HOSTS`、`KIKI_SERVER_ENV` 覆盖本机配置路径；`KIKI_SERVER_HOST` 适用于同一证书 IP 的连接检查，迁移 IP 需重新签发证书及更新 App 地址和固定指纹。服务器需 Python 3.11+、openssl、systemd，443 端口需可访问。

备份脚本在 SQLite 写锁内复制数据库和当前被引用的头像，生成包含 `kikitalk.sqlite3`、`avatars/` 的时间戳目录；读取服务保持可用，写操作短暂等待。旧版只有 `.sqlite3` 的备份不包含头像。恢复时先停止服务，将同一份备份的数据库及头像目录一并复制回原路径，恢复 `kikitalk:kikitalk` 所有者、数据库/图片 `0600`、头像目录 `0700`，移除同名旧 `-wal`/`-shm` 后启动服务。不要在服务运行时直接覆盖 SQLite 文件。脚本按当前正式环境默认数据路径备份；如设置自定义目录，需同时调整备份源路径。

## 账号与身份

用户只输入 ID，格式为 3–32 位英文字母、数字、下划线或短横线，大小写敏感。首次登录创建账号并绑定安装设备的随机 256 位密钥；密钥由 App 放进 Keychain，登录时随 HTTPS 请求提交，服务端只保存加盐后的 PBKDF2 哈希。其他设备不能只凭已存在的 ID 冒用账号。首次 ID 登录后必须设置 1–16 字昵称；`needsNickname=true` 时，服务端拒绝创建房间、标记开播和记录进入房间，返回 `409`，提交合法 `PATCH /v1/me` 的 `name` 后解除。升级时，旧账号仍使用 ID 默认昵称（含旧版截断的 16 字 ID）会要求补昵称，已自定义的昵称保留；迁移只执行一次。没有额外的密码输入框；跨设备迁移、设备丢失后的账号找回需要后续账号恢复能力。

Bearer 会话使用 256 位随机值，数据库只存 SHA256 哈希，有效期 30 天，已登录客户端刷新时顺延。UserSig 服务端签发，有效期 24 小时；腾讯云 SecretKey 从不发给客户端。退出登录只撤销当前会话；注销账号删除全部会话、身份绑定、资料和个人资料库，并将旧房间登记标记结束。重新注册相同 ID 会获得新的腾讯云用户身份，不能继承原身份。

`identities` 表已将身份提供方与业务账号分开。以后接入 Apple 时，应在新认证端点验证 Apple identity token 的签名、issuer、audience、有效期和 nonce，使用已验证的 `sub` 绑定 `provider=apple`，保留业务账号和 SDK 身份。当前未开放 Apple 认证端点。

## API 合约

除健康检查、ID 登录和公共头像读取外，所有端点需要 `Authorization: Bearer <token>`。时间均为 Unix 秒；历史排序内部使用纳秒防止同一秒多次浏览排序不稳定。错误统一返回 `{ "detail": "中文说明" }`，敏感参数和 bearer 不写入访问日志。JSON 等普通请求体最多 16 KiB；仅 `POST /v1/me/avatar` 的二进制头像上传允许最多 2 MiB，分块请求同样受限。额外 JSON 字段会被拒绝。

| 方法及路径 | 输入 | 输出 |
| --- | --- | --- |
| `GET /health` | 无 | `{status:"ok", rtcConfigured:true}` |
| `POST /v1/auth/id` | `{userID, deviceSecret}`，deviceSecret 为 64 位十六进制 | `{token,user,sdk}` |
| `POST /v1/auth/refresh` | 无 | `{user,sdk}`，保留同一 token 并延长会话 |
| `POST /v1/auth/logout` | 无 | `{ok:true}` |
| `GET /v1/me` | 无 | User |
| `PATCH /v1/me` | 可选 `{name,bio,avatarIndex,notificationsEnabled}` | User |
| `POST /v1/me/avatar` | 原始 JPEG 二进制，`Content-Type: image/jpeg`，最多 2 MiB | 更新后的 User |
| `GET /v1/avatars/{64位随机十六进制}.jpg` | 无需认证，只读 | `image/jpeg` |
| `DELETE /v1/account` | 无 | `{ok:true}` |
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

头像存储目录默认是数据库同级的 `avatars/`，可通过 `AVATAR_DIRECTORY` 配置；URL 前缀通过 `PUBLIC_BASE_URL` 配置，当前固定为 `https://43.138.219.160`。SDK 默认图片加载器不自动信任本站私有证书，客户端须沿用本项目固定证书校验的图片加载路径，不能关闭证书验证。

`sdk = {sdkAppID, userID, userSig, expiresAt}`，其中 `userID` 等于 `User.sdkUserID`。

`Room = {id,title,host,hostID,hostAvatarIndex,hostAvatarURL,audience,isLive,theme,category,isCreatedByMe,status,createdAt}`。`hostAvatarURL` 为房主自选头像绝对 HTTPS URL 或 `null`。`hostID` 为腾讯云 SDK 用户 ID；主题索引 0–5；标题最多 40 字且 UTF-8 编码不超过 100 字节，分类最多 12 字。语聊 ID 前缀为 `voice_kiki_`，直播为 `live_kiki_`。

登记不是在线状态的判定依据。API 不猜测在线人数，`audience` 固定为 0；客户端以腾讯云返回的实际房间列表及累计观看人次合并展示，房内成员由 SDK 实时显示，并按 SDK 在线房间 ID 分批调用 `rooms/lookup` 获取对应元数据，避免历史登记较多时漏掉仍在线的旧房间。收藏和历史保存结束房间以保留真实记录。房主创建 SDK 房间成功后标记 `live`，退出并结束后标记 `ended`；如果客户端异常退出，首页仍依据 SDK 在线列表移除失效房间。

## 验证

```bash
python3 -m venv backend/.venv
backend/.venv/bin/python -m pip install -r backend/requirements-dev.txt
backend/.venv/bin/python -m pytest -q backend/tests
```

当前 22 项测试通过。测试覆盖首次昵称约束、旧数据库昵称迁移、头像认证/格式/尺寸/体积/路径验证、EXIF 清除、替换/预设/注销清理及房主同步，并覆盖 UserSig 协议、设备绑定、会话过期和撤销、跨账号权限隔离、资料同步、房间状态、收藏、历史去重、注销和身份重建，以及输入、请求大小和速率限制。

UserSig 协议参考腾讯官方实现：[Tencent-RTC/tls-sig-api-v2-python](https://github.com/Tencent-RTC/tls-sig-api-v2-python)。
