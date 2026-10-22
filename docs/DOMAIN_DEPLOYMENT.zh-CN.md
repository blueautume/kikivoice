# kiki.group 官网与业务域名部署

部署日期：2026-10-16（北京时间）。官网按 Sites 技能的静态页面流程制作，按用户要求部署在现有自有服务器，没有使用额外托管平台。

## 访问入口

| 用途 | 地址 |
| --- | --- |
| 官网 | https://kiki.group/ |
| 业务 API | https://kiki.group/v1/ |
| 健康检查 | https://kiki.group/health |
| HTTP | 308 跳转到同一路径的 HTTPS |
| 可选 www | 已配置 HTTPS 到主域名的跳转，但 DNS 尚无 www 记录；需要时添加 CNAME：`www → kiki.group` |

当前根域名 A 记录指向现有服务器。无需配置 api 子域名。腾讯 RTC/IM 仍由 SDK 访问其服务网络，不经自有 API 中转媒体流。

## 部署结构

- Nginx：公网 80/443，TLS 1.2/1.3，完整证书链；未知 Host/直接 IP 不提供业务接口。
- 官网：`/var/www/kikitalk/current`，指向 `/var/www/kikitalk/releases/20261016T153352Z`。
- 后端：systemd `kikitalk`，独立系统用户，仅监听 `127.0.0.1:8000`。
- Nginx 配置：`/etc/nginx/nginx.conf`、`/etc/nginx/conf.d/kiki.group.conf`。仓库源位于 `backend/deploy/`。
- 后端设置：`PUBLIC_BASE_URL=https://kiki.group`；既有数据库、会话和头像目录保留，头像 URL 动态按新域名返回。
- Nginx 覆盖来源 IP/协议/Host 转发头，Uvicorn 只信任回环代理，保留真实来源限流。普通 API 请求体上限 16 KiB，头像上传 2 MiB；应用层继续二次校验。
- API 文档端点不开放，API/官网访问日志关闭；静态目录独立于业务数据和凭据目录。

## 证书和私钥

本次采用用户提供的 TrustAsia 证书，SAN 包含 `kiki.group`、`www.kiki.group`，有效期至 **2027-01-14 20:59:59（北京时间）**。未配置自动签发续期。

| 位置 | 内容及权限 |
| --- | --- |
| 本机 `~/.config/kikitalk/tls/kiki.group/` | 目录0700，原证书包提取的私钥/证书文件0600，位于仓库外 |
| 服务器 `/etc/nginx/tls/kiki.group/fullchain.pem` | 完整证书链，root:root，0644 |
| 服务器 `/etc/nginx/tls/kiki.group/privkey.pem` | TLS私钥，root:root，0600；所在目录0700 |

证书续期时先在受限临时目录上传新文件，核对私钥匹配、域名和有效期；备份旧证书对，再替换以上两个文件，执行 `nginx -t` 后执行 `systemctl reload nginx`，最后用系统 CA 校验公网 `https://kiki.group/health`。校验失败时恢复旧证书对并重新检查/加载。不要用 `curl -k` 当作验收结果。正常续期无需改 App；不应将私钥放进 website、App 或 Git。

## 更新与回滚

后端日常更新使用 `bash backend/deploy/deploy.sh`，保留服务器现有环境凭据，不再生成自签 IP 证书；从 Nginx 域名验证健康。开发、测试和生产凭据应按原流程在受限位置维护。

官网源文件为 `website/dist/`。更新时上传到新的 `/var/www/kikitalk/releases/<时间戳>/`，检查资源后原子切换 `current` 软链；回滚时切回上一版本软链，不涉及业务数据库。首次迁移的受控安装器 `backend/deploy/install_domain.py` 在 root 私有 staging 目录执行，验证证书后创建配置/数据库/头像备份，再安装并验证；失败自动恢复原配置和进程。该安装器不执行数据库恢复，也不覆盖正在运行的数据库。

本次修改前保存：

- 本机 Git 基线：`codex/backup-before-domain-20261016-232501`。
- 本机未提交文件/补丁：`~/.local/share/kikitalk/backups/before-domain-20261016-232501`（包括用户原有 Xcode 修改）。
- 服务器原配置/应用：`/var/backups/kikitalk/before-domain-20261016T152707Z/configuration-and-application.tar.gz`。
- 数据库及头像：`/var/backups/kikitalk/kikitalk-20261016T152709154953Z/`。
- 切换时完整快照：`/var/backups/kikitalk/domain-install-20261016T153352Z/`，包含 `previous.tar.gz`、一致的数据库和头像副本；仅 root 可访问。

需要回退到旧 IP 方案时，先停 Nginx 和业务进程，从 `previous.tar.gz` 恢复原应用、环境、systemd 配置；执行 daemon-reload 并启动原业务服务。原自签证书保留在受限 `/etc/kikitalk`，用于完整回退；它已不参与当前公开 HTTPS。不要直接覆盖正在运行的数据库；只有确认要回退数据时才按后端恢复流程处理同一快照数据库与头像。

## 验收结果

- 公网官网200，页面内容匹配；HTTPS 系统 CA 验证通过，证书主机名匹配。
- HTTP 308，未认证 `/v1/me` 401，OpenAPI/文档404；普通和头像请求体上限验证。
- systemd 两服务 active，业务端口仅回环监听；私钥权限0600。
- iOS 模拟器19项普通测试通过；域名真实联调1项通过，覆盖登录、昵称、上传/刷新、API 与 Kingfisher 双图片下载、真实八麦房间创建/结束；测试账号清理。
- 后端23项测试通过，含配置域名输出与伪造 Host 不污染头像 URL。
- 官网图片资源和锚点正常，检查320/390/768/1024/1440宽度；修复小屏网格最小宽度及装饰轨道横向溢出。

旧安装包固定旧 IP 与证书，需安装本次域名版本。既有账号的 Keychain 会话可继续刷新，登录/恢复时同步腾讯 SDK 头像到新域名。官网没有编造下载渠道或备案号；如提供已取得的备案信息，可补到页脚。

参考：[Nginx HTTPS](https://nginx.org/en/docs/http/configuring_https_servers.html)、[FastAPI 代理信任](https://fastapi.tiangolo.com/advanced/behind-a-proxy/)。
