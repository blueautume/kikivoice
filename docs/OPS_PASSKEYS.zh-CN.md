# Kiki 运维统一 Passkey 账户

> 后续 P0 发布新增独立 `community` 权限，支持举报与语聊处置；原 `account`、`voice` 两个看板权限继续只读，互不自动扩权。见 [P0 交付说明](P0_COMMUNITY_SAFETY.zh-CN.md)。

本轮仅替换 Kiki 运维 App 的管理口令，不改变普通 KikiTalk 用户的 Apple 登录。账号服务器 `kiki.group / 43.138.219.160` 统一保存运维身份、Passkey 公钥、会话与权限；语聊服务器 `furby.top / 139.224.50.108` 不另建一套运维账号。

## 使用与授权

1. 在 Kiki 运维中创建通行密钥，或使用已有通行密钥登录。首次登录后设置自己的姓名。
2. 默认没有任何看板权限，第一位注册者也不自动成为管理员。界面显示姓名及不可变的 `ops_` 账号编号，姓名可以重复。
3. 负责人明确指定“姓名＋账号编号＋需要的看板”后，再通过账号服务器本地 CLI 开通 `account`、`voice` 中的一项或两项权限。客户端和公网 API 都不能授予权限。
4. 权限逐次查询，撤权后原有会话也无法继续请求相应看板。改名不会合并同名账号或继承权限；授权 CLI 要求与当前姓名精确匹配。

统一身份与服务数据来源分别处理：App 向 `kiki.group/admin/v2` 登录和请求数据，账号服务器检查指定看板权限，语聊数据经独立签名内部接口读取，界面仍标明数据来自 `furby.top`。运维会话不作为普通 Apple 业务凭据或 LiveKit 媒体凭据使用。

## 服务端维护命令

从账号服务器的 `/opt/kikitalk` 目录执行。通过 root SSH 发起维护操作，但以 `kikitalk` 服务用户访问数据库，避免 SQLite WAL/SHM 文件属主竞态；无需把私密环境文件交给客户端。不要向 App 暴露这些命令：

```bash
runuser -u kikitalk -- env DATABASE_PATH=/var/lib/kikitalk/kikitalk.sqlite3 /opt/kikitalk/venv/bin/python -m app.ops_auth list
runuser -u kikitalk -- env DATABASE_PATH=/var/lib/kikitalk/kikitalk.sqlite3 /opt/kikitalk/venv/bin/python -m app.ops_auth grant --account-id ops_实际编号 --name '实际姓名' --service account
runuser -u kikitalk -- env DATABASE_PATH=/var/lib/kikitalk/kikitalk.sqlite3 /opt/kikitalk/venv/bin/python -m app.ops_auth grant --account-id ops_实际编号 --name '实际姓名' --service voice
runuser -u kikitalk -- env DATABASE_PATH=/var/lib/kikitalk/kikitalk.sqlite3 /opt/kikitalk/venv/bin/python -m app.ops_auth revoke --account-id ops_实际编号 --name '实际姓名' --service voice
```

删除运维身份使用同一 CLI 的 `delete --account-id ... --name ...`；这会撤销该身份的会话、凭据与权限，保留必要的操作审计，不触碰普通 Apple 账号。丢失通行密钥不会通过同名自动找回旧权限：可使用系统同步的凭据，或注册一个零权限新身份，再由负责人核验并明确重新授权。

## 认证和配置边界

- RP ID 固定 `kiki.group`，验证 origin 固定 `https://kiki.group`。挑战一次性、120 秒有效，强制用户验证；会话最长 8 小时，服务器只保存哈希。
- 运维 App Bundle ID 为 `com.kikitalk.voiceops`，Associated Domains 为 `webcredentials:kiki.group`。AASA 的 `webcredentials.apps` 为 `A82X46N3WS.com.kikitalk.voiceops`，通过 HTTPS 固定文件提供，无重定向。
- 两台服务器均设置 `ADMIN_AUTH_MODE=passkey`，旧 `/admin/v1` 管理口令及令牌不能访问管理数据。旧口令哈希从生产环境移除；普通语聊和 Apple 会话不清除。
- 两端共享一把全新的运维服务间密钥 `OPS_BRIDGE_SECRET`，不复用 Apple、LiveKit 或业务账号桥接密钥。本机受限文件为 `~/.config/kikitalk/ops-bridge.secret`，只进入两台服务器的 `0600` 环境文件。
- 内部语聊看板仅接受账号服务器 IP，且仍需校验固定路径、固定请求体、独立 HMAC、时间戳及持久一次性 nonce。客户端运维 Bearer、姓名、账号编号和权限不发送至语聊服务器。
- 运维身份与公钥保存在独立 `ops_*` 表中；语聊服务器只存短期签名 nonce，没有运维人员账号副本。

接口字段见 [Passkey 合同](../experiments/livekit/shared/ops-passkey-contract.json)。独立运维隐私说明为 `https://kiki.group/ops/privacy/`，不修改普通 App 的协议版本。

## 验证范围

离线测试及软件 P-256/ES256 凭据用于验证真正的 WebAuthn 服务端验签、默认零权限、同名隔离、按看板授权和撤权，不代替系统 Passkey 界面或真实 Face ID / Touch ID。正式设备仍需本人完成系统授权；本轮不自动为任何真人或第一位注册者授予权限。

2026-10-19 已完成部署与自动验收：

| 项目 | 实际结果 |
| --- | --- |
| 两台主机 | `ADMIN_AUTH_MODE=passkey`，生产环境已移除旧口令哈希；旧管理登录/看板/退出均返回 404。相关 systemd 服务均为 active，两端源码与本地哈希一致。 |
| 备份 | 两台主机分别保留 `/root/kiki-ops-passkey-backups/20261019T082039Z`，包含一致 SQLite、旧代码、配置与发布文件；账号服务器另含头像及旧网站。 |
| 账号后端 | 221 项通过，其中 35 项新运维认证/ACL/网关回归；另 6 项独立安全探针通过。 |
| 语聊后端 | 267 项通过，其中 15 项新运维网关及事务锁回归。 |
| 运维 App | 最终正常签名测试 24/24 通过、0 跳过、0 失败：`/tmp/kiki-ops-passkey-public.xcresult`。其中公网测试覆盖真实软件 ES256 验签签发的会话、双服务待授权页、授权后 4 个看板及退出后 401；5 张截图已逐张目视检查。 |
| 权限隔离 | 同名的两个临时账号未合并且最初均无权；分别授 account、voice 时另一项仍 403；撤销后同一会话立即失去权限；双权限仅给明确的临时验收身份。 |
| 临时数据 | 两个测试账号及其公钥凭据、会话、权限均已删除，临时私钥和会话副本已清理；保留维护审计记录。未给任何真人或首用户自动授权。 |
| App 与域名关联 | generic iOS device 构建/实际签名通过，AppID/Associated Domains 核验正确；站点 AASA 与 Apple CDN 均 200，匹配同一 AppID。未代替本人进行真机系统授权。 |
| 普通业务 | Apple 账号、凭据与业务会话保留，语聊媒体配置与 4 房/每房 32 人/全服 64 人准入限制未变。 |

部署时新增依赖最初因过严文件权限导致账号 API 未能启动，已修复为服务用户可读取公共运行库，并以 `kikitalk` 用户完成导入检查后恢复服务。配置、数据库及密钥仍保持受限权限。后续安装公开 Python 依赖应采用可供服务用户读取的权限，并在重启前检查实际服务用户的导入结果。

验收汇总和截图见 [结构化结果](../experiments/livekit/validation/ops-passkeys-2026-10-19/result.json)。Xcode 已打开运维工作区，scheme 为 `KikiVoiceOps`；需要本人重新运行新版，完成系统 Passkey 创建/登录、命名与待授权页面确认。向负责人提供当前姓名、完整编号及希望开通的看板后再人工授权。

恢复备份前应暂停管理接口并核对版本及权限数据；不要为排障自动启用 `legacy` 或恢复旧口令。回滚不得自动授权第一位注册者，或把同名当成身份恢复依据。
