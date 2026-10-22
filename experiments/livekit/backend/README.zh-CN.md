# 独立 LiveKit 语聊实验后端

此目录仅服务语聊服务器 `139.224.50.108` / `furby.top`，不导入账号服务 `backend/`。正式模式已通过签名桥接接入账号服务的 Apple 登录和资料，运维使用统一 Passkey；下文邀请码/旧口令段落仅为实验模式历史说明。支付赠礼、视频、录制和语音内容识别未接入，容量配置继续保留原 4 房／每房 32 人／全服 64 人。

## 社区安全 P0（2026-10-19）

完整端点、字段、权限和保留期见 [`../shared/p0-safety-contract.json`](../shared/p0-safety-contract.json)。已增加持久化举报、个人拉黑、基础文字词表过滤、运营处置与按账号去重的语聊活跃数据，不涉及普通 Apple 账号封禁、付费能力或硬件扩容。

- 普通用户 `GET /v1/safety` 查看拉黑、最近通知和临时限制；`PUT/DELETE /v1/safety/blocks/{userID}` 返回完整安全状态。拉黑只隐藏本人收到的对应消息和公告，客户端负责不订阅其媒体；公开房间在线和共同在场不隔离。
- `POST /v1/safety/reports` 提交人／房／消息举报，必须有服务器 SFU 观察到的真实参与记录。消息正文、作者和房间归属由数据库核实，不接受客户端自造证据；`GET /v1/safety/reports/mine` 查看本人提交状态。UUID 重试幂等、每分钟 3 条、24 小时 20 条（持久总量跨重启）。
- 管理员必须在账号服务单独取得 `community` 权限，再通过固定签名代理访问两个语聊路径：`POST /internal/admin/v2/moderation/query`、`.../action`。签名绑定方法、精确路径和原始 body SHA256，与只读 dashboard 共享一次性持久 nonce 池；不接受客户端运营 Bearer、任意目标或跳转地址。Nginx 只允许账号服务器源 IP，不提供公网直达管理写接口。
- 处置包括警告、临时文字禁言／禁麦／语聊封禁、关闭房间、驳回和解除平台限制。禁止以房管取消禁言、重新登录、旧 JWT 或信令重连绕过。先持久化限制，再同步 SFU 发布权限并停止已有音轨；确认失败则关闭信令、尝试移除媒体，维护任务持续重试。`mediaCleanupPending` 必须在管理端显示为待确认，不能当作完整清退成功。解除平台限制不会覆盖房主设置的房内禁言。
- 举报与按需消息证据、处置通知、实际参与观察记录最长 30 天；不录制音视频。举报过期不会提前解除较晚施加的制裁，`activeRestrictions` 保留最小来源编号和有效限制，仍可执行 `restore_user`。有效限制最长 30 天，到期自动清除并同步媒体权限。
- 最小操作审计和幂等回执 90 天。注销／撤回清理双向拉黑、关联举报证据、通知及活跃标识，并清空审计自由文本和目标业务 ID，仅保留有期限的 opaque 回执；正式注销完成后删除制裁。撤回同意不能用于绕过尚有效的语聊封禁。备份另按 7 天轮换，不承诺历史副本物理即时擦除。
- `operations.activity` 从 `trackingSince` 起记录语聊账号活跃、近 35 天回访、SFU 去重在线、采样估计房间停留、授权上麦和举报计数；35 个上海自然日后删除标识。缺新鲜在线采样为 `null`，停留不补算进程重启或采样中断，不能与准入占位／SFU 原始连接数混用。
- `SAFETY_TERMS_PATH` 可选指定只含 `{"blockedTerms":["短语"]}` 的 UTF-8 JSON（最多 2000 条、每条 2–80 字符），启动时验证。过滤房名、分类、文字聊天和公告，规整全角、空格和零宽格式字符。未配置时仅有有限默认短语；它需要人工举报配合，不代表完整内容审核。
- 只读看板新增 `maintenance.backup`，只读固定 `/var/lib/kiki-livekit-lab/backup-status.json` 收据。尚无收据显示未知；最后验证失败或最后成功超过 36 小时告警；不向 App 暴露备份路径或日志细节。

## 运行与隔离

Python 3.10+，依赖固定在 `requirements.txt`；测试依赖在 `requirements-dev.txt`，运行 `pytest -q`。必须单 worker，业务/会话/房间权限/入场登记/文字 seq 用同一异步锁序列化，SQLite 保存权威状态。

```sh
uvicorn app.main:app --host 127.0.0.1 --port 8010 --workers 1 --no-proxy-headers --no-access-log
```

Nginx 覆盖 `X-Real-IP` 并且 `/v1/`、`/admin/v1/`、`/rtc` 前缀全部代理到此进程；含 `/rtc`、`/rtc/validate`、`/rtc/v1` 和 `/rtc/v1/validate`。8010/7880 不得对公网开放，`/twirp/` 不对公网代理；否则会绕过业务权限检查。信令网关只转发固定 loopback LiveKit，不信客户端的上游地址、身份或旧令牌中的发布权限。

| 环境变量 | 值 / 默认 |
| --- | --- |
| `LAB_DB_PATH` | 独立路径，例如 `/var/lib/kiki-livekit-lab/lab.sqlite3` |
| `LEGAL_DOCUMENTS_PATH` | 部署的 `shared/legal_documents.json` 绝对路径 |
| `LIVEKIT_URL` | 必须 `http://127.0.0.1:7880` |
| `LIVEKIT_PUBLIC_URL` | 必须 `wss://furby.top` |
| `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` | 实验专用凭据，secret 至少 32 字符 |
| `LAB_ACCESS_CODE` | 至少 16 字符，主机私密提供 |
| `LAB_MAX_ACTIVE_ROOMS` | 4 |
| `LAB_MAX_ROOM_PARTICIPANTS` | 总人数 32，最多 8 麦，其余为听众 |
| `LAB_MAX_TOTAL_PARTICIPANTS` | 64 |

本轮按用户选定的 4 房 / 每房 32 人 / 全服 64 人设置准入；64 是登记上限，不表示已通过稳定容量验收，延迟不作为本轮验收门槛。领 token 尚未完成连接、断网恢复期间的活跃登记也占额度；同一活跃身份重复领 token 不重复占用。创建/领 token/信令入场在锁内检查；房间满返回 409，总人数或房数满返回 429、`Retry-After: 30`。LiveKit 必须 `room.auto_create: false`；每次显式创建设置每房上限、`empty_timeout=600`、`departure_timeout=180`。实例配置也应与上述上限保持一致。

有效业务会话各 180 请求/分钟，已鉴权共享 IP 总量默认 18000/分钟；匿名与无效 Bearer 仍受 6000/分钟/IP 总量与 240/分钟/IP 匿名额度，登录另限 10/分钟/IP。伪造 Bearer 或 `X-Real-IP` 不能制造新额度。请求体最多 16 KiB，响应禁止缓存。请求体、查询 token、SDK SDP、消息正文及凭据不得写访问日志。

## 会话、麦位和退出

`POST /v1/auth/lab` 接收 `{name,accessCode,legalConsent}`，协议版本/哈希及成年确认必须匹配当前文档。每次创建随机实验身份，业务 Bearer 为 256 bit 随机值，仅存 SHA-256，绝对有效期 7 天；refresh 不延长。协议不匹配返回 428 和 `requiredVersions`。客户端独立 Keychain 保存自己的业务会话。

`POST /v1/rooms/{id}/token` 仅接收 Bearer（不接收客户端身份/角色），返回 `{serverURL,participantToken,room}`。JWT 5 分钟、只限指定房间与本人，会话摘要和入场 generation 由服务器签入 metadata；默认听众只能订阅与发文字。信令入口每次重新验证当前会话、generation、禁入与麦权，并重签当前上游权限，所以旧 speaker JWT 无法恢复被收回的发布权限。禁止摄像头、屏幕共享和客户端修改 metadata。

`GET /v1/rooms/{id}/state` 返回权威 8 麦、成员、角色、队列、邀请、禁入列表（仅管理者）与 revision。`POST .../actions` 支持 `request_seat/cancel_request/approve_request/reject_request/invite_seat/accept_invite/decline_invite/leave_seat/move_seat/remove_seat/lock_seat/lock_audio/mute_audio/mute_chat/set_admin/kick/unban`；身份权限、目标层级与席位抢占都由服务器判定。房主独有任命管理员及结束房权；管理员不能处分房主或其他管理员。禁麦/禁言同步 LiveKit 原生权限，移除麦位会停止发布；解禁不会替客户端自动开麦。

轮询热路径每次用一条联表查询实时找出全局失效会话/协议成员；不缓存权限或到期判定。完整房间模型先只读检查，只有缺失 revision、麦位或迁移成员时才补写；已在线且断线时间为空的成员不反复写入 presence。GET state 只查询目标房的 SFU 成员，以及其他房中已到 120 秒持久断线边界、必须立即确认是否重连的成员；每次仍 ListRooms，及时关闭媒体端已消失的房间并刷新全局实际人数。普通稳定 state 因而固定为一次目标 ListParticipants 加一次 ListRooms，不随其他在线房间数量增加。一次请求内复用清理阶段取得的在线集合，期间发生权限变更、移除或关房会使该请求快照失效并重新读取。创建/领 token/管理操作和每 5 秒后台维护仍全局同步，容量保护保持全局实时保守；全部房间仍由原全局锁协调，此优化没有把 SFU 网络请求移到锁外，也不代表已完成生产级横向扩容。

`POST .../leave` 为本人显式离房。退出账号、撤回同意、注销、被踢和显式离房立即撤销入场，不享受网络宽限；业务会话到期同样清理。网络意外断开则保留麦位与 generation **120 秒**，保持 SDK 重连可恢复，不必重新取 token。后台每 5 秒检查持久 `offline_since`，进程重启仍能清理过期占位。

房主离房/退出时优先转交在线且会话有效的管理员，再选在线成员；无人接任才关空房。只有房主明确 PATCH `status:"ended"` 才结束整房。LiveKit 的单用户 RemoveParticipant 自身不能撤销自托管旧 JWT，所以还要关闭对应受控信令连接并由入口持续检查。权限/移除意图落库到 `media_cleanup`，未确认的退出返回 503 可重试，不能虚报成功。注销意图保存在 `deletion_requests`，完成媒体清理与房主交接后擦除资料/收藏/最近访问；不影响同房其他成员。

## 有序文字、补偿与公告

`POST /v1/rooms/{id}/messages`：

```json
{"clientMessageID":"客户端生成的 UUID","text":"文字"}
```

文本 trim 后非空、最多 **2000 UTF-8 字节**，拒绝非法控制字符；未知字段（含 sender）拒绝。返回 200 的 `ChatMessage`：`{id,seq,clientMessageID,senderUserID,senderName,senderAvatarIndex,text,createdAt}`。服务器生成 id、递增房间 seq、取当前鉴权身份及昵称头像；时间为 Unix 秒，clientMessageID 标准化小写 UUID。同房同用户同 UUID 同内容重试返回原件，异内容 409；幂等范围为仍保留的消息窗口。业务限频每用户每房 5 条/5 秒、30 条/分钟，429 带 `Retry-After`；同内容幂等重试不计次数。

`GET .../messages?afterSeq=0&limit=200` 返回：

```text
{messages, nextAfterSeq, latestSeq, oldestSeq, truncated, hasMore,
 historyRevision, announcement:{text,revision,updatedAt,updatedByUserID}}
```

默认/最多 200 条，正序；`afterSeq=0` 重建当前窗口，其他值增量拉取，`hasMore` 时以 `nextAfterSeq` 续页。seq 永不因裁剪复用；过旧或超前 cursor 以 `truncated` 提示重建。`historyRevision` 初始 0，仅实际删除/到期/裁剪后增加，客户端发现变化应从 0 重建，以消除已删除内容。公告初始空、revision/updatedAt 为 0、作者为 null；`PUT .../announcement {text}` 仅房主/管理员，2000 字节，可空以清除，同文重试不增 revision。

读写都必须为当前有效且与入场会话匹配的活跃成员，无禁入、房间未结束。禁言可读不可写；退出、被踢、撤回、注销不能拉历史；合法重新入房可见当前滚动窗口。每房仅保留最近 **200 条且最长 2 小时**，关房即删除文字，撤回/注销立即删除该账号的消息和其最后编辑的公告。SQLite/WAL/人工备份可能仍有残页，这只是业务查询窗口，不承诺底层物理介质即时擦除，也无法撤销其他人已收到的文字。

持久化提交成功后，官方 RoomService SendData 使用 RELIABLE topic **`kiki.chat.sync`** 广播 `{version:1,latestSeq,historyRevision,announcementRevision}`。提示不带正文，广播失败不把已提交消息变为失败；断线/丢提示通过增量 HTTP 轮询补偿。客户端不可显示旧 `kiki.chat` 或任意客户端自报 sender/正文，也不应仅凭 data 包更新历史，HTTP 结果是唯一依据。

## 临时诊断

有效会话可 GET `/v1/diagnostics`，只返回五分钟连接计数、握手中位数、去标识质量聚合和容量，不含昵称、身份、IP、room ID 或会话摘要。`activeParticipants` 只有完整且 10 秒内的 SFU 在线快照才为数字，否则 null；`admittedParticipants` 是容量占位人数，两者含义不同。

活跃成员可 POST `/v1/rooms/{id}/quality`，body `{quality:"unknown|excellent|good|poor|lost",rttMs?,jitterMs?,packetLossPercent?}`；有限非负值才接受，未知/不支持的值省略，每会话 10 秒最多一次，202 `{accepted:true|false}`。样本只在内存五分钟，最多 1000 条；独立的每秒维护任务清理到期数据，不依赖新上报、查询或媒体服务响应。会话摘要仅用于十秒节流，不进入聚合样本、不落库。告警阈值用于实验排障，不是生产 SLA 或自动扩容。

`GET /health` 实际调用 LiveKit ListRooms，仅在可达时返回 200；这不能代替双端真实音频和异常网络人工验收。服务端边界以固定 `livekit-api==1.2.2` 官方 SDK 类型与 `livekit-server v1.13.10` 协议为准；本目录 `test_sdk.py` 验证 CreateRoom、权限与 SendData 的实际请求字段。

## 独立只读运营管理接口

管理接口仅面向 `voice-lab` / `furby.top` 语聊实验单机。账号服务没有连接、没有请求地址、没有复用账号服务凭据。完整 JSON 对接契约见 `../shared/admin-api-contract.json`。管理 App 首版只能查看数据，尚无强制关房、封禁、服务重启等写接口；Apple 管理登录也尚未开放。

新增配置：

| 环境变量 | 值 / 默认 |
| --- | --- |
| `ADMIN_PASSPHRASE_HASH` | 留空则管理登录关闭。格式 `pbkdf2_sha256$600000$<32位小写十六进制salt>$<64位小写十六进制摘要>` |
| `ADMIN_TLS_CERT_PATH` | `/opt/kiki-livekit-lab/shared/server-certificate.pem`；仅公共完整证书链，API 进程不能读取私钥 |
| `LAB_HTTP_AUTHENTICATED_IP_LIMIT` | 18000/分钟，范围 6000–60000；只有服务器查到有效会话才使用此共享网络桶 |

在 backend 目录用 `python -m app.admin hash-password` 交互输入并确认独立口令，终端只输出带随机盐的摘要。口令须为 16–256 UTF-8 字节，保留空格，不得与 `LAB_ACCESS_CODE` 相同。不要将口令、其摘要、管理 token 或私密环境文件写入 Git、截图、访问日志或测试结果。将摘要安全加入服务器 root 私密环境文件后重启 API。管理 hash 配置错误拒绝启动；留空关闭管理但不影响普通语聊 API。

- `POST /admin/v1/auth/session {passphrase}`：签发独立随机 256 bit viewer Bearer，8 小时绝对有效期。SQLite `admin_sessions` 仅存 SHA-256、到期/撤销时间和口令配置指纹，最多 32 个有效会话；不创建普通用户。口令校验在线程执行，最多 2 个并发，不排无限工作队列。登录固定每 IP 5 次/5 分钟、全局 30 次/5 分钟，失败 401、限流 429 带 `Retry-After`。更换 hash 会使旧管理会话失效。
- `DELETE /admin/v1/auth/session`：只撤销当前管理会话，200 `{revoked:true}`。普通用户 token 与管理员 token 互不通用，普通邀请码不能登录管理台。
- `GET /admin/v1/dashboard`：管理 Bearer 必填，只读；响应统一 `Cache-Control: no-store`，错误不回显请求正文。有效管理会话每分钟最多 60 个请求。

运营数据按 **Asia/Shanghai** 自然日统计。当前房间、今日成功创建/结束、累计房间来自业务 SQLite；新增生命周期附表和触发器不更改原房间表。迁移前的结束日期未知，不推断为迁移日，响应包含 `roomEndTrackingSince`。参与身份是语聊入场记录去重，邀请码每次登录会生成不同实验身份，不代表真实用户数或账号 DAU。

容量同时显示配置上限、活跃登记和 SFU 实际连接数，三者不能混用。管理台每约 10 秒异步更新 LiveKit ListRooms 快照，超过 10 秒或采样失败即把实际人数标记 `null` 与 `sfuStale:true`，保留真实采样时间；既有普通诊断采样方式保持不变。房间列表只提供标题、类别、人数、8 麦占用和角色数量，不返回用户身份、昵称、IP、会话、JWT 或消息正文。

连接/质量仍是当前 API 进程最近 5 分钟的有限内存样本，不落库，重启清空。`successPercent` 定义为窗口内 `accepted/(accepted+rejected)` 的已完成信令接入成功比例；不把处理中的尝试混入分母，也不等同双端收到音频的成功率。没有完成事件时为 `null`。质量中位数没有对应样本也为 `null`。

Linux 主机 CPU/内存/磁盘/网络速率/启动时长、固定四个 systemd 服务状态和公共 TLS 证书到期信息在线程中采集，缓存约 10 秒；四个固定 `systemctl is-active` 各 0.5 秒超时，整个异步等待最多 5 秒。超过 30 秒将主机快照标记过期；首个 CPU/网络样本无差值时为 `null`，采样失败不伪造 0。证书不可读、SFU 不可用、主机采样过期都显式显示未知/告警。CPU/内存/磁盘达到 85%、证书不足 30 天、固定服务 failed/inactive、媒体清理待确认等产生看板内告警，尚不推送外部通知，也不自动重启或扩容。

### 创建、入房与运行问题记录（2026-10-19）

新增 `POST /v1/telemetry/incidents`：有效业务登录和当前同意下上报白名单结构化事件，语聊封禁用户仍可提交。服务端确定公开账号编号及昵称，不接收用户自报身份、错误原文、任意 URL、token、IP、房间或消息正文。iOS/iPadOS 只上报失败或警告，主动取消和正常离房不作为故障。`X-Kiki-Attempt-ID` 关联一次创建/加入尝试，每次 HTTP 响应返回由服务器生成的 `X-Kiki-Request-ID`；创建、token、状态 API 的失败另由服务端独立持久记录，区分客户端观测与服务器观测。

`room_incidents` 保存 SQLite 内，重启保留，最长 7 天、全局最多 10000 条。客户端路径与账号服务 fallback 共用事件 UUID 幂等和每用户 20 条/分钟、100 条/日的配额；可信账号/语聊服务观测使用独立的合计 30 条/分钟、300 条/日配额。同一运行尝试内相同音频质量警告在 60 秒内合并。服务端只映射安全错误码为中文说明，原始错误文本不进入数据库。

账号服务通过精确路径 `/internal/v1/account/incident` 的既有业务桥签名补报，支持尚未成功换取语聊会话的账号；这不会创建语聊用户或授予房间权限。新增撤回信封的可选 `accountID` 字段，使没有语聊用户的账号也可清理事件；独立同意撤回水位最多保留 32 天，防止迟到 outbox 重建旧事件。正式注销清理事件及该最小水位，既有哈希注销 tombstone 继续拦截旧授权。

语聊看板新增顶层 `incidents` 汇总和最近 50 条，失败尝试数按公开账号＋attemptID 去重，不能视为失败率。固定运维签名路径 `POST /internal/admin/v2/incidents/query` 支持级别、操作、公开昵称/编号筛选和最多 50 条游标分页，账号网关须逐次检查 `voice` 查看权限；普通业务用户没有问题记录读取接口。完整模型和枚举见 `../shared/room-incidents-contract.json`。

部署须将新 `app/incidents.py` 一同复制；Nginx 公共语聊路由增加 `/v1/telemetry/incidents`，两条新增内部路径继续只允许账号服务来源，不能将 `/internal/` 暴露为公共接口。不需要新增密钥或修改容量配置。新记录不能还原升级前未采集的具体客户端超时。
