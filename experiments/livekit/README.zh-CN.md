# KikiTalk 语聊服务与运维目录

更新日期：2026-10-22。目录名沿用 LiveKit 实验阶段，但下列代码仍被当前产品使用。

| 目录 | 当前职责 |
| --- | --- |
| `backend/` | 正式语聊业务 API、房间准入/麦位/聊天/礼物、LiveKit 信令网关 |
| `admin-ios/` | 独立 KikiVoiceOps 管理 App；Passkey 运维身份、看板和社区治理 |
| `infra/` | 语聊媒体/API 配置、部署、维护、备份与探针 |
| `shared/` | 跨服务契约、语聊协议副本 |
| `validation/` | 本地生成、按日期归档的验收证据，未纳入 Git |

用户 App 的唯一主线在 `application/Demo/`。打开仓库根目录的 `application/RTCube.xcworkspace`，选择 **KikiTalk**；管理端打开 `admin-ios/KikiVoiceOps.xcworkspace`，选择 **KikiVoiceOps**。用户端依赖通过 SPM 管理，管理端使用系统框架。

旧 `ios/KikiLiveKitLab` 实验客户端和 `vendor/` 腾讯参考快照已在本次 iOS 清理移除。正式 Apple 账号由 `kiki.group` 认证，再桥接到 `furby.top` 的独立语聊会话；生产使用 `VOICE_AUTH_MODE=account`。运维只向 `kiki.group` 进行 Passkey 登录，由中央身份的逐项 ACL 授权。此清理没有部署后端、变更生产配置或修改正式协议。

当前开发入口见[项目接手指南](../../docs/PROJECT_HANDOVER.zh-CN.md)和[架构说明](../../docs/ARCHITECTURE.zh-CN.md)；服务及管理端各自说明见[语聊后端](backend/README.zh-CN.md)、[管理 App](admin-ios/README.zh-CN.md)。

## 归档范围

**以下保留 2026-10-19 独立实验阶段的原始配置、运行步骤及验收。** 其中旧 iOS 路径、邀请码身份、vendor、双口令运维、固定协议版本和当时的功能限制已不构成当前入口；相关工程已移除，不能执行旧客户端命令。实验后台、infra、shared 仍保留，具体行为以其当前代码与生产配置为准。历史通过数量、截图、证书及部署状态不代表 2026-10-22 重新验证。下文 `validation/` 链接指本地归档证据，该目录与根 `output/` 均未纳入 Git，克隆仓库不会自动取得。

> **归档：切换初期说明（2026-10-19）：** 当前工作区正在将本目录已验证的语聊能力移植至原 `application/RTCube.xcworkspace` 的 KikiTalk。正式应用保留 Apple 登录，账号服务为 `kiki.group`（`43.138.219.160`），自建语聊为 `furby.top`（`139.224.50.108`）；语聊使用 `VOICE_AUTH_MODE=account`，64 人总准入上限、最多4房且每房32人。独立运维 App 已实现两台服务器分别登录及分别展示指标。 服务器实际部署、备份、协议及真机待验状态见 [LiveKit 停机切换](../../docs/LIVEKIT_CUTOVER.zh-CN.md)。

> **归档：后续运维认证说明：** 运维 App 现在只向 `kiki.group` 进行 Passkey 注册/登录，由中央运维身份的独立 ACL 决定能否查看账号或语聊看板；新身份及第一位注册者均无默认权限。生产两端设置 `ADMIN_AUTH_MODE=passkey`，旧口令和 `/admin/v1` 会话不可用于生产，也没有密码回退。`furby.top` 只接收账号服务器签名的只读聚合请求，不另存运维姓名或权限。操作步骤与验收见 [运维 Passkey 说明](../../docs/OPS_PASSKEYS.zh-CN.md)。

## 归档：独立实验阶段说明

下文保留独立实验阶段的配置、功能与历史验收。切换后原 iOS 和账号后台已接入自建语聊，不再适用“原项目不变”的历史边界；生产 `account` 模式也不接受下文实验昵称/邀请码登录。独立实验 App 若需继续使用，必须另配明确的 lab 环境，不能按旧步骤登录已切换的正式语聊服务。旧历史测试与图片不作为本轮发布验收。

独立 iOS 工程已以 LiveKit 替换腾讯 SDK，专用业务后台和媒体服务已部署；P0 麦位与权限回收之外，本轮补齐 P1 可靠消息、最小化、音频与重连适配、质量诊断和单机容量保护。原 Kiki iOS 工程、正式后台和服务器保持独立。

## 实验边界与功能

| 项目 | 现有 Kiki 语聊 | LiveKit 实验 |
| --- | --- | --- |
| iOS 工程 / scheme | `application/RTCube.xcworkspace` / KikiTalk | `ios/KikiLiveKitLab.xcworkspace` / KikiLiveKitLab |
| Bundle ID | `com.kikitalk.demo` | `com.kikitalk.livekitlab` |
| 桌面名称 | Kiki语聊 | Kiki实验版 |
| 业务域名 | `https://kiki.group` | `https://furby.top` |
| 服务器 | 原有服务器 | `139.224.50.108` |
| SSH 别名 | 原有配置 | `furby-livekit-lab` |
| 客户端 RTC | 腾讯 SDK | Swift Package Manager 固定 LiveKit `2.18.0` |

实验版保留紫色大厅、「我」、建房和语聊房的界面风格，提供独立昵称登录、真实房间列表、**8 个独立麦位＋听众**、麦克风开关、成员和发言状态、房间文字消息、公告、房主结束房间，以及资料、收藏和最近访问。当前按用户选定的准入配置，默认最多 4 个活动房间、每房 32 人、全服 64 个入场名额；未完成媒体连接的预入场也计入，避免并发绕过。64 是本轮选定的准入上限，不表示已通过稳定容量验收；延迟不作为本轮验收门槛。

P0 提供申请和取消排队、审批和拒绝、限时邀请并由本人接受、下麦和换麦、锁麦位及锁音频。房主可任免管理员；房主和管理员可禁麦、文字禁言、移出并封禁、解除禁入，管理员不能处罚房主或同级管理员。听众默认没有音频发布权限，获批和解除禁麦后均需本人主动开麦。

P1 提供房间最小化和返回同一连接、HTTP 权威聊天与幂等发送、最近消息和断线补拉、管理员公告、音频路线和中断处理，以及网络质量诊断。视频直播、礼物与钱包、照片上传尚未开放；头像使用内置预设。实验 target 已移除所有腾讯 SDK 依赖，`vendor/` 仅保留原代码快照作参考，不参与当前构建。

普通语聊显式使用 Opus 语音档（最大 24 kbps），保留 SDK 的 DTX 静音抑制和 RED 冗余；避免默认音乐档为纯语音占用额外带宽。容量验收以连续合成音频、24 kbps 最大码率、关闭 DTX 且保留 RED 测试，覆盖多人持续发言的负载；不代表将来音乐或立体声模式的容量。

另有完全独立的只读运营运维 App，见 [`admin-ios/README.zh-CN.md`](admin-ios/README.zh-CN.md)。它使用单独 Bundle ID 和中央 Passkey 运维会话，不与普通语聊客户端会话互通；下文旧管理口令仅为历史记录。

实验 App 使用独立 Bundle ID、Keychain service、协议确认和用户偏好存储，不覆盖正式 App 或恢复其账号。实验后台不导入正式后台代码、环境文件或数据库。

## 归档：实验客户端运行步骤（工程已移除）

在仓库根目录执行：

```bash
open experiments/livekit/ios/KikiLiveKitLab.xcworkspace
```

1. 等待 Xcode 自动解析 Swift Package，选择 **KikiLiveKitLab** scheme。
2. 选择 iPhone 模拟器或已配置签名的真机，按 `⌘R`。最低 iOS 17，开发团队为 `A82X46N3WS`。
3. 确认以「Kiki实验版」独立安装，阅读并确认实验协议与成年声明。
4. 输入昵称和实验邀请码。邀请码仅保存在本机 `~/.config/kikitalk-livekit-lab/lab-access-code`，权限 `0600`；通过本机受限文件获取，不提交 Git、不写入 App 或 scheme。
5. 两个测试端分别登录，一端创建语聊房，另一端刷新并加入。房主默认占 1 号麦，其他人作为听众；先申请上麦并由管理者批准，再点击「开麦」申请系统麦克风权限。依次验证双向声音、文字消息、排队、管理动作和房主结束后双方离房。

当前工程使用 SPM，**无需执行 `pod install`**。实验登录不使用 Apple，也不需要 Sign in with Apple 能力。

每次输入邀请码登录都会新建随机实验账号。已登录设备只将业务会话保存到 Keychain，可在 7 天有效期内恢复；邀请码不保存在设备。退出后再次登录会创建新账号，原账号无法找回。不要把正式账号或真实个人资料用于实验。

房间封禁按实验账号生效；重新昵称登录会得到新身份。正式使用前需要接入稳定账号体系，不能将本实验的匿名身份当作针对真人的永久封禁。

## 新服务器与网络

服务器运行 Ubuntu 24.04，LiveKit Server 固定 `1.13.10`，以原生 systemd 服务部署：

| 服务 | 配置 / 数据 | 职责 |
| --- | --- | --- |
| `livekit-lab` | `/etc/livekit-lab/livekit.yaml` | LiveKit 信令、WebRTC 媒体与 TURN |
| `livekit-lab-api` | `/opt/kiki-livekit-lab/backend`；环境文件 `/etc/livekit-lab/api.env` | 独立 FastAPI 后台，监听 `127.0.0.1:8010`，单 worker |
| HAProxy | `/etc/haproxy/haproxy.cfg` | 公开 TLS 443，解密后区分 HTTP/WebSocket 与 TURN/STUN |
| Nginx | `/etc/nginx/sites-available/furby.top` | 本机 `127.0.0.1:8443` 接收可信 PROXY protocol，反代业务和信令 |
| SQLite | `/var/lib/kiki-livekit-lab/lab.sqlite3` | 实验账号、会话、协议与房间记录 |

TCP 443 的 HTTP/WebSocket 流量经 HAProxy 转发给 Nginx，再到 API `8010`。所有 `/rtc`、`/rtc/v1` 及两种 `/validate` 入口先经过会话网关，核验后才转发给本机 LiveKit `7880`；TURN/STUN 流量转发到 LiveKit `5349`，配置 `external_tls` 和 PROXY protocol。TURN 对外广告 `turns:furby.top:443`，只需 `furby.top` 的 DNS 和证书，不依赖新增 `www` 或 TURN 子域名解析。

云安全组与 UFW 均需要放行以下端口；仅配置主机防火墙不足以保证公网可达。`7880`、`8010`、`5349` 不向公网开放：

| 端口 | 用途 |
| --- | --- |
| TCP 22 | 专用 SSH 连接 |
| TCP 80 | 跳转 HTTPS |
| TCP 443 | HTTPS、WSS 与 TURN/TLS |
| UDP 443 | TURN/UDP |
| TCP 7881 | WebRTC TCP |
| UDP 7882 | WebRTC UDP |

2026-10-19 补齐实验机云安全组的 UDP 443、7882 后，带标记的两端口探测均 8/8 到达，真实双端音频从 TURN/TLS 中转切换到 PRFLX/UDP 直连。此前中转路径的满载 CPU 数据保留作历史对照，不能作为放行后 UDP 路径的容量上限。

`GET /health` 会实际调用 LiveKit ListRooms。可达时返回 200，例如：

```json
{"ok":true,"service":"kiki-livekit-lab","provider":"livekit","rtcConfigured":true}
```

不可达时返回 503。健康检查表示 API 能连接媒体服务，不能替代双端真实声音验证。配置模板和服务文件保存在 `infra/`；运行中的密钥只保存在服务器受限文件中。

## 账号、麦权与单用户退出

后台以 256 bit 随机业务会话鉴权，仅保存其哈希；refresh 不延长 7 天有效期。入房时另外签发 5 分钟 JWT，限定实验账号、指定房间、麦克风、数据发布和订阅，不授予视频、屏幕共享或房间管理权限。客户端不持有 LiveKit API secret。

自建 LiveKit 不能直接逐条撤销 JWT，因此本实验在信令入口增加独立网关。JWT 只作为带签名的身份凭据，每次入房和重连还需匹配有效业务会话、房间、入场代次和禁入状态。网关使用当前数据库权限重签上游令牌，旧的发言令牌也不能恢复已经撤销的麦权；服务端权限变化同时调用 LiveKit UpdateParticipant 和必要的媒体静音或移除。

普通离房只释放本人的入场、麦位、排队和邀请。退出登录、撤回同意、注销或会话过期时，仅撤销该账号连接；房主优先转交给在线且会话有效的管理员，其次其他在线成员，没有合适接替者才关闭房间。房主主动选择「结束房间」仍会结束整房。

网络断开单独保留 120 秒入场和麦位宽限，SFU 房间最后一人离开后的等待时间为 180 秒。显式离房、踢出、退出账号和撤回不享受该宽限，立即撤销。重连使用 SDK 自动刷新的绑定令牌，保留入场代次；恢复前重新核对麦位和权限。纯网络恢复可以继续本人此前已开启且仍获授权的麦克风；发生禁麦、下麦、系统音频中断或耳机拔出时必须手动再开。API 单独重启可以恢复连接；媒体服务本体重启仍可能结束活动房间，本实验未部署多节点容灾。

权限及媒体清理意图持久保存，后台确认媒体服务更新或移除成功后才报告清理完成；失败会禁止重入并重试。注销意图也持久保存，完成清理后匿名化资料。已过期或撤销凭据仅能重试对应终止操作，不能恢复业务访问。客户端撤回时立即停止媒体，未获服务器确认会显示待重试状态。信令网关依赖单进程内的连接注册表，当前 API 必须保持 **单 worker**；扩为多实例前需要共享连接控制与事务协调。

实验法律文本的单一来源是 [`shared/legal_documents.json`](shared/legal_documents.json)，客户端副本为 `ios/Demo/Resources/KikiLegalDocuments.json`，后台部署同一 JSON。修改文本后须同步版本、内容哈希和两端文件；协议不匹配返回 428，并阻止继续使用业务。

## P1 消息与诊断

文字正文由业务 HTTPS 接口鉴权并分配房内递增序号，发送者来自当前会话。客户端以 `clientMessageID` 在当前保留窗口内幂等重试；LiveKit `kiki.chat.sync` 仅广播序号提示，提示丢失时定期补拉，客户端不显示数据包自报的正文或发送者。查询提供最近 200 条、最长 2 小时的滚动窗口，支持新成员历史、断线增量、窗口截断和删除后的重建。公告仅房主与管理员可改。禁言成员可收听及读取，不能发送；离房、踢出或房间结束后不能查询。

关闭房间或作者撤回、注销时清理对应业务正文；滚动查询窗口不是底层数据库/WAL或人工受限备份的物理擦除期限。新协议版本为 `2026-10-19-livekit-lab3`。

房内诊断显示本机音频路线、系统中断、连接质量及能取得的 RTT、抖动和丢包；缺失数值显示未知，丢包比例来自当前接收统计的累计计数。`GET /v1/diagnostics` 仅登录后可读，返回最近 5 分钟的连接计数、握手耗时、质量聚合、容量和阈值提示，不返回账号、IP、房名、令牌或原始样本。质量上报每会话至多 10 秒一次，样本和限频表都有严格数量上限，只在进程内短时保存，重启清零。重连计数统计协议可识别的 quick resume，不能把它视作全部网络故障次数。当前没有外部通知、长期监控仓库或多地域大盘。

已认证请求按会话限流 180 次/分钟，同 IP 的有效会话总量独立限制 18000 次/分钟；匿名或无效凭据仍使用 240 次/分钟/IP，邀请码登录继续限制 10 次/分钟/IP。这样同一 Wi-Fi 的多人状态与聊天同步不会共用原来的低额度。

信令注册也有总量保护：默认最多 256 条活跃或待握手连接，每个身份最多 4 条，保留正常的近同时重连；超额在替换原连接前返回 429，不会挤掉健康连接。

## 独立运营运维 App

当前版本使用统一 Passkey 身份，登录后设置姓名，服务器手动分别授予账号/语聊查看权限。运维 App 的数据请求只发往 `kiki.group/admin/v2/`；账号服务器每次核对授权，并经独立 HMAC 网关读取 `furby.top` 的语聊聚合数据。语聊服务器拒绝客户端运维 Bearer。登录、注册、零权限提示及当前验收见 [运维 Passkey 说明](../../docs/OPS_PASSKEYS.zh-CN.md)。这项变更不改变普通 KikiTalk 的 Apple 登录，也不向第一位注册者自动授予权限。

### 历史：双服务口令首版（生产已停用）

以下独立口令、旧 Keychain 和 `/admin/v1` 描述只保留首版实现与验收历史，不可作为生产登录方式。双服务首版说明见 [`admin-ios/README.zh-CN.md`](admin-ios/README.zh-CN.md)。在 Xcode 打开 `experiments/livekit/admin-ios/KikiVoiceOps.xcworkspace`，选择 `KikiVoiceOps`；主屏幕名称“Kiki运维”，Bundle ID `com.kikitalk.voiceops`，不覆盖语聊 App。看板只读，没有结束房间、封禁或重启服务器等操作。

顶部分别选择 **语聊服务 `furby.top`** 和 **账号服务 `kiki.group`**，使用不同口令、Keychain 会话和数据模型。语聊口令路径为 `~/.config/kikitalk-livekit-lab/admin-passphrase`，账号口令路径为 `~/.config/kikitalk/admin-passphrase`，均为项目外 `0600` 文件；服务器各自仅配置自己的 PBKDF2 哈希，管理会话最长 8 小时。这里的 Apple 管理登录仍未实现，和正式 KikiTalk 的 Apple 业务登录分开。

语聊看板展示房间、SFU 在线人数、入场名额、麦位、连接/质量聚合及语聊主机资源；账号看板展示账号、有效业务会话、Apple 授权撤销队列、头像/数据库占用及账号主机资源。两边未知值不填零，过期采样标注，前台每 15 秒刷新。“语聊参与身份”与“有效账号会话”均不代表账号 DAU；`accountService.connected=false` 仅表示语聊响应不含账号指标，不是账号 provider 未配置。

**历史首版验收：** 仅语聊版本曾通过 19 项签名模拟器测试（包含真实公网登录/看板/退出失效与系统 Keychain），0 失败、0 跳过。该批历史页面为 [运营概览](validation/voice-ops-overview-2026-10-19.png)、[服务运维](validation/voice-ops-infrastructure-2026-10-19.png)，记录为 [`validation/voice-ops-result-2026-10-19.json`](validation/voice-ops-result-2026-10-19.json)，不代表本轮双服务公开接口已经验收。双服务离线签名回归为 27 项执行、25 通过、2 项公开测试显式跳过、0 失败；实际发布及后续公开验收统一写入 [停机切换记录](../../docs/LIVEKIT_CUTOVER.zh-CN.md)。

## 密钥、SSH 与证书

以下本机文件均在项目外，不属于源码、App 资源或 Git：

| 用途 | 路径 | 权限 |
| --- | --- | --- |
| SSH 私钥 | `~/.ssh/furby_livekit_lab.pem` | `0600` |
| 固定主机公钥记录 | `~/.ssh/furby_livekit_lab_known_hosts` | 严格校验实验主机 |
| 本机 SSH 别名配置 | `~/.ssh/furby_livekit_lab.conf` | `0600` |
| 实验邀请码 | `~/.config/kikitalk-livekit-lab/lab-access-code` | `0600` |
| 原始 TLS 证书及私钥 | `~/.config/kikitalk-livekit-lab/tls/furby.top/` | 目录 `0700`，文件 `0600` |

提供的 SSH 私钥和原始证书包已移入以上受限存储；原始压缩包为 TLS 目录中的 `original-nginx.zip`。不要把这些文件复制回工程。

```bash
ssh furby-livekit-lab
# 不依赖本机全局 Include 的方式，在仓库根目录运行：
ssh -F experiments/livekit/infra/ssh_config furby-livekit-lab
```

本机原有 `furby-top` 别名指向另一台旧服务器，实验部署使用 **furby-livekit-lab**。固定的 ED25519 主机公钥指纹为 `SHA256:mfWnUJMjGu+7narXpK7YfaNaPuJnRNK9jxybGLMQLYE`，来自首次 SSH 记录，未通过云控制台独立核对。

服务器证书覆盖 `furby.top`、`www.furby.top`，有效期至北京时间 **2027-01-16 19:59:59**，尚未配置自动续期。相关文件：

- 证书链：`/etc/nginx/tls/furby.top/fullchain.pem`。
- TLS 私钥：`/etc/nginx/tls/furby.top/privkey.pem`，`root:root`、`0600`。
- HAProxy 合并证书与私钥：`/etc/haproxy/private/furby.top.pem`，`root:root`、`0600`。
- TLS 受限备份：`/var/backups/furby-livekit-lab/tls-<UTC时间>/`。

续证时在本机受限 TLS 目录更换匹配的证书和私钥，再从仓库根目录运行：

```bash
python3 experiments/livekit/infra/deploy_tls.py
```

该脚本用于**已安装阶段 2 服务的服务器**，不是首次安装脚本。它限定专用 SSH 配置和实验 IP，核对域名、证书与私钥匹配及至少 7 天有效期，备份后同步 Nginx 文件、HAProxy 配置及合并 PEM；通过 `nginx -t`、`haproxy -c` 后重载两项服务，并以系统 CA 校验公网 HTTPS。失败时尝试恢复备份和两项服务配置；SSH 同时中断时，使用受限备份人工恢复。

## 验证状态与复测

2026-10-19 的 P1 验证结果：

| 检查 | 状态 |
| --- | --- |
| 独立后端测试 | 198 项通过，覆盖消息幂等与裁剪、诊断边界与闲置清理、容量、恢复及信令权限 |
| iOS 签名构建和整套测试 | 37 项通过，0 失败、0 跳过；含真实系统 Keychain 与 4 项公网测试 |
| 4 个公网 RTC 客户端 / 2 个隔离房间 | 通过；跨房历史拒绝，公告权限、消息确认与重试、禁言、作者删除后窗口重建通过 |
| 公网断线与重连 | 21 秒离线后保留麦位、补拉消息；离线期间禁麦后旧令牌重连仍受限；SDK 刷新令牌保留业务会话绑定 |
| 重连期限 | 业务配置 120 秒、SFU departure timeout 180 秒；119 秒边界有后端测试覆盖，公网离线用例实际为 21 秒 |
| 实验 API 重启 | 四个真实 SDK 连接恢复，不重启媒体服务；媒体节点故障转移未实现 |
| 真实 Swift 最小化与恢复 | 同一 RoomSID、页面和未发草稿保留，最小化期间消息补齐，公告、离房及房主转交通过 |
| 双向合成音频 / TURN TLS | 收取 816 / 1469 帧，非零 245 / 249 帧；双端 TLS 中转，禁麦收回已发布音轨 |
| 诊断与容量保护 | 登录鉴权、有界聚合、限频和超限不影响已有房间通过；质量样本为合成数据，不是网络性能基准 |
| 真实来电、蓝牙、锁屏和两台真机互听 | 待人工验收；自动测试中的系统中断为模拟通知 |

汇总见 [`validation/p1-validation-summary-2026-10-19.json`](validation/p1-validation-summary-2026-10-19.json)，公网恢复和媒体记录分别在 [`validation/p1-result-2026-10-19.json`](validation/p1-result-2026-10-19.json)、[`validation/transport-p1-result-2026-10-19.json`](validation/transport-p1-result-2026-10-19.json)。[P1 真实 Swift 房间截图](validation/livekit-p1-room-real-2026-10-19.png)展示恢复后的公告、最小化期间收到的消息和保留的草稿。完整 iOS 结果包位于本机 `/tmp/kiki-p1-final-real.xcresult`。

最终复核补充了迟到发送确认的游标保护，防止重新插入已裁剪消息或删除后的空洞；HTTP 先收到禁麦状态时，也会同步关闭本机音频输入。诊断另有每秒独立清理任务，闲置时也会移除过期样本，不等待媒体服务。当时 P1 的 4 房 / 每房 32 人 / 全服 64 入场属于历史保护配置，不表示完成容量压测、多节点容灾或外部自动告警；当前默认配置见本文开头。

以下保留 P0 历史验证结果：

| 检查 | 状态 |
| --- | --- |
| 独立后端测试 | 127 项通过，含 51 项信令网关专项和真实 Uvicorn/wsproto 测试 |
| iOS 签名构建和整套测试 | 28 项通过，0 失败、0 跳过；含真实系统 Keychain 与 3 项公网测试 |
| 9 个公网真实 RTC 连接 | 通过；强制 TURN，8 麦之外仍可加入听众 |
| 排队和并发抢麦 | 通过；唯一空位同时审批仅 1 个成功，另一请求返回 409 |
| 禁麦、文字禁言与旧发言令牌 | 通过；真实 SDK 权限下降，旧令牌重连被重签为当前受限权限，禁言数据不送达 |
| 邀请、麦位锁和音频锁、管理员层级 | 通过 |
| 踢出、旧令牌重入、解除禁入 | 通过；四个信令入口拒绝旧凭据，解禁后需新入场令牌 |
| 单用户退出及房主账号注销 | 通过；成员退出保留其他 8 条连接，房主注销转交在线管理员，后者可显式结束整房 |
| 真实 Swift 客户端转交和管理 | 通过；原房主 SDK 立即退出，接任者原连接保留，审批/禁麦/禁言同步原生 SDK，解禁不自动采集 |
| 双向合成音频与 TLS 中转 | 通过；598 / 1175 帧，非零 220 / 224 帧；双方选中 TURN/TLS，双向文字送达，强制禁麦收回已发布音轨 |
| 两台真机人工互听 | 待人工验收 |

9 端结果保存在 [`validation/p0-result-2026-10-19.json`](validation/p0-result-2026-10-19.json)。另外修补了 LiveKit `publish` 查询参数可能改写身份的问题，网关四个入口均拒绝这类非空参数，并覆盖重复参数的情况。API 的 WebSocket 日志级别为 warning，避免 Uvicorn 将 JWT 或 SDP 查询参数写入连接日志。

本轮汇总见 [`validation/p0-validation-summary-2026-10-19.json`](validation/p0-validation-summary-2026-10-19.json)，双向媒体明细见 [`validation/transport-p0-result-2026-10-19.json`](validation/transport-p0-result-2026-10-19.json)。[P0 真实 Swift 房间截图](validation/livekit-p0-room-real-2026-10-19.png)展示 8 个麦位、独立听众、两位真实参与者及双向消息。修复后的 iOS 完整结果包在本机 `/tmp/kiki-p0-verified-real.xcresult`。测试账号已清理，服务器没有遗留活动房间或待清理媒体任务。

撤销活跃连接时，网关先发送 LiveKit 官方 `Leave(action=DISCONNECT)` 终止消息，再关闭信令并确认 SFU 移除；否则 Swift SDK 会将裸 WebSocket 关闭当成临时网络错误并持续重连。该消息区分被移除和整房结束，支持二进制及 JSON，不改变握手撤销屏障，也不把普通断网或服务重启误报为封禁。

此前的阶段 2 基础验证记录：

| 检查 | 状态 |
| --- | --- |
| 独立后端测试 | 35 项通过 |
| iOS 构建与测试 | 完整构建通过；全套 21 项测试通过、0 失败、0 跳过，包含 2 项真实联网测试 |
| 正常签名与 Keychain | 额外 1 项真实系统 Keychain 增删改查测试通过；使用正常 ad hoc 签名，已安装同一签名 App 供手动运行 |
| 公网 API 真测 | 登录、协议、建房、房间令牌及终止操作通过 |
| 双端真实媒体 / TURN | 通过；两端收取 789 / 790 帧，非零测试音频 366 / 388 帧；强制 relay 时双方选中的中转协议均为 TLS |
| Swift SDK 真实房间、双向消息和房主结束 | 通过；新 KikiRTCService 实际呈现房间，2 位真实参与者、双向消息及真实发送者，房主结束后客端收到 roomDeleted |
| 真机双向麦克风和人工交互 | 待人工验收 |

媒体验证的无凭据结果保存在 [`validation/transport-result-2026-10-19.json`](validation/transport-result-2026-10-19.json)。[实际 Swift 语聊房截图](validation/livekit-room-real-2026-10-19.png)来自真实新服务连接及消息，不是界面占位数据。测试账号已结束房间并注销。

常用检查，在仓库根目录运行：

```bash
curl --fail --show-error https://furby.top/health
ssh -F experiments/livekit/infra/ssh_config furby-livekit-lab \
  'systemctl is-active livekit-lab livekit-lab-api haproxy nginx'

xcodebuild test \
  -workspace experiments/livekit/ios/KikiLiveKitLab.xcworkspace \
  -scheme KikiLiveKitLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

模拟器 App 需要正常签名才能使用 Keychain，手动运行不要关闭 `CODE_SIGNING_ALLOWED`。Xcode 已打开实验 workspace，可选择模拟器或已配置签名的真机运行；本轮更新了实验协议版本，旧版本同意记录需重新确认。

后端测试在独立虚拟环境安装 `backend/requirements-dev.txt`，进入 `experiments/livekit/backend` 执行 `pytest -q`，不需要真实邀请码或正式数据库。真实联网测试须显式提供环境中的实验邀请码，不要将其值写入命令记录、源码或共享 scheme；`xcodebuild` 向测试进程传递变量使用 `TEST_RUNNER_` 前缀。

[`infra/smoke_media.py`](infra/smoke_media.py) 是可选的双端音频与数据验证脚本，读取本机受限邀请码文件，使用临时实验账号和生成的测试音，不采集物理麦克风、不打印凭据；需要独立安装 `livekit==1.1.21` 和 `httpx==0.28.1`。加 `--relay-only` 可强制使用 TURN，结果只记录传输类型，不记录候选 IP、SDP 或鉴权凭据。API 测试、生成测试音和模拟器测试均不能替代两台真机互听验收。

[`infra/smoke_p0.py`](infra/smoke_p0.py) 提供 9 端真实连接、并发审批、角色、禁麦禁言、旧 JWT、踢出与房主转交验收，额外依赖 `aiohttp==3.14.5`。会创建临时实验账号，请避开其他邀请码登录测试的每分钟 10 次限制。退出登录用例的凭据已撤销，只能重试退出；该测试账号的匿名化需由运维依据受限、仅含本轮账号 ID 的 `/tmp/kiki-p0-created-accounts.json` 完成。本次验收账号均已清理。

[`infra/smoke_p1.py`](infra/smoke_p1.py) 以 4 个 RTC 客户端、5 个临时账号验证两个隔离房间、服务端消息确认与幂等、公告和禁言、窗口清理、21 秒离线期间保留麦位并执行禁麦、SDK 刷新令牌以及容量保护。加 `--restart-api` 会通过固定的 `furby-livekit-lab` SSH 配置重启实验 API，验证四个 SDK 连接恢复，不重启媒体服务；此时不要同时运行其他公网验收。脚本不采集物理麦克风，质量上报用已标明的合成诊断样本，不能将其当作网络性能数据。
