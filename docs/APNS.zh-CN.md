# 系统通知接入

日期：2026-10-19，Asia/Shanghai。范围为 KikiTalk 主 App 的私聊和已有站内互动系统提醒；运维 App 仅查看账号服务的汇总状态，不接入自身推送。最终发布与验收以文末结果索引为准。

## 2026-10-20 启动权限更新

权限时机改为“本地协议同意 → 网络检查 → 系统通知授权 → Apple 登录”，协议同步为 `2026-10-20-r8`；r7 和更早留存页保持不变。系统网络询问由 iOS 决定，不添加局域网、Bonjour 或私有权限 API。网络检查使用固定自有账号域名、系统 TLS、无 Cookie／账号／设备令牌，10 秒请求／20 秒资源上限、最多 4096 字节；没有修改两台服务器的业务逻辑或账号偏好。验证与发布状态见 [启动权限结果](../experiments/livekit/validation/startup-permissions-2026-10-20/result.json)。后续真机验证由用户完成，本次不安装、启动真机或发送测试通知。

## 服务与密钥

- Apple 团队 `A82X46N3WS`，固定 topic `com.kikitalk.demo`。开发签名使用 Sandbox，TestFlight／App Store 使用 Production；客户端按实际签名环境登记，不按 DEBUG 判断。
- 发送端只有 `kiki.group / 43.138.219.160` 的账号服务。`furby.top / 139.224.50.108` 继续负责语聊与权威拉黑，不保存 APNs 私钥、不发送系统通知。
- 两套用户提供的 APNs `.p8` 位于本机项目外私有目录，目录 0700、文件 0600。账号服务器使用 `/etc/kikitalk/apns/`，目录 root:kikitalk 0750、密钥 root:kikitalk 0640；私钥不进入 Git、App、日志或业务数据库。
- `configure_apns.py check-local` 检查本地密钥为 EC P-256 并预编译远程配置脚本；`stage` 私下经 SSH stdin 配置两环境且关闭发送；`enable` 核对已暂存密钥后一并启用环境变量。两种远程操作均保存 root 私有回滚副本，不自行重启服务。
- 现有 Apple 登录私钥用途不变。设备令牌使用既有服务端加密密钥加密保存；原始安装 UUID 不作为公开设备标识展示。

## 用户体验与权限

首次同意当前协议后，应用先等待前台并通过自有账号服务的无凭据 `/health` 检查网络，再在进入 Apple 登录前申请系统通知权限；已有系统决定时不重复申请。普通公网访问没有单独的公开授权请求 API，实际联网可让系统按设备规则显示网络询问，不能保证每台设备弹框；健康检查失败提供重试和系统设置入口。联网检查、通知询问完成前不创建业务 Store 或发起登录。通知拒绝或请求异常均可继续登录；登录前不注册 APNs、不读设备标识或上传 token、不修改账号通知开关。消息和设置仍提供稍后开启入口；系统授权、当前账号提醒开关、有效会话及当前隐私协议同时满足后登记设备。被系统拒绝后使用系统设置入口更改。

默认横幅只显示固定通用提醒，不包含私聊或评论正文、发送者昵称、图片、房间名称。通知点击只携带随机事件标识，由账号服务根据当前登录身份重新解析目标；通知不是内容访问凭证。当前同一会话前台阅读时避免重复横幅，未读状态以服务器为准。

退出和切号清理本机通知、角标及待跳转状态并解绑对应会话；撤回、注销和 Apple 授权撤销清理该账号全部绑定及待发任务。安装级单调版本用于拒绝换号前迟到的注册请求，旧操作不能覆盖新绑定。

## 队列与可观测性

业务提交与持久待发记录关联，网络投递在短事务之外进行；重试使用固定事件标识与有限退避，处理 APNs 限频和短暂故障。发送前再次校验会话、协议、开关、事件有效性与权威屏蔽关系；无法取得屏蔽策略时延后发送。

设备绑定至会话失效或 30 天未更新，以较早者为准；待发任务最长 24 小时；终态投递记录与点击解析事件最多 7 天；必要安装版本水位最多 30 天。过期任务不再发送。APNs 永久设备失效结果按对应绑定版本清理，旧响应不能删除更新后的设备。

APNs 200 表示 Apple 已接收，不表示设备已展示、用户已收到或已读；超时重试不能承诺严格只送一次。已交给 Apple 的通知无法保证立即撤回，可能迟到；到期时间、通用文案和点击后鉴权用于限制影响。关闭提醒保留站内消息。

账号看板仅显示聚合配置、队列及预设技术故障，不展示令牌、私钥、安装编号或用户正文。常规 API 访问日志保持关闭。

## 发布与验证

四份协议升级为 `2026-10-19-r6`，主 App、两端服务和官网同步；已发布的 r5 及更早留存文本保留。主 App 的 Device ID 隐私类别仅用于 App Functionality，关联账号，不用于跟踪；未代用户填写 App Store Connect 隐私表单。

构建使用正常 Xcode 签名并刷新含推送 entitlement 的描述文件；主 App 的展示型推送没有新增静默后台模式、PushKit 或第三方推送 SDK。

最后结果保存到 [本轮验收目录](../experiments/livekit/validation/apns-2026-10-19/)。无效合成 device token 的连通性探测仅说明请求抵达 APNs，不能替代真机设备 token 的成功接收、锁屏展示和点击验证。真实 iPhone／iPad 仍需安装本轮版本并主动允许通知。

官方依据：[注册 APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)、[通知授权](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)、[APNs HTTP/2](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns)、[APNs 返回码](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)。

## 本轮发布结果

账号服务已启用两环境 APNs，语聊服务同步 r6 协议，LiveKit 媒体进程未重启。线上账号与语聊源码分别为 16／12 个受检文件，与本地哈希一致；两端 API、备份定时器及 SFU 正常。验收清理后再次完成一致性备份与校验。

| 验证 | 结果 |
| --- | --- |
| 账号后端 | 365 通过；其中 APNs 专项 26 项通过。 |
| 语聊后端 | 334 通过，验证同步 r6 后的既有行为。 |
| 主 App | 100 项：99 通过，1 项额外凭据集成测试跳过，0 失败。 |
| 运维 App | 66 项：65 通过，1 项额外凭据集成测试跳过，0 失败。 |
| iPad 通知界面 | 单项截图验证通过；iPhone 与 iPad 前台截图均已目视核对。 |
| 公网验收 | 14／14 通过，28 项测试数据及碰撞审计计数全部为 0。 |
| 签名和安装 | 主 App 与 Ops 均严格验签通过；主 App 已安装到连接的 iPhone 15 Plus 和 iPad Air 5，现有 iPhone Ops 已更新。 |
| 当前主包 APNs | 描述文件和签名均为 development，运行使用 Sandbox；Production 发送配置已启用，供之后的 TestFlight／正式签名包使用。 |

APNs 上线批次 r6 的文档集合 SHA-256 为 `1ae8fda0b65df1552e2cfc7584facdd8af19061367ae8c44dfb3ef9055e13b0c`。当时当前页、r6 留存页及 r5 旧留存页的公网核对均通过，匿名推送业务读取被拒绝。后续一次确认界面更新为 r7，见 [隐私更新记录](APP_STORE_PRIVACY.zh-CN.md)。

公网 14 项使用已证明不属于真实设备的固定全零 token，实际后台 worker 在两个 APNs 环境得到 `bad_device_token` 并正确清理绑定。该批次只证明队列、鉴权及拒绝处理链路。随后用户在两台设备允许通知，并明确授权实际通知测试：两条精确绑定的通用提醒均一次获得 APNs accepted，无重试；用户确认 iPhone 与 iPad 均收到通知且点击正常。此后仅清理这两条测试站内通知和投递记录，保留真实设备绑定。详细结果见 [真机测试记录](../experiments/livekit/validation/apns-2026-10-19/live-device-smoke.json)。

本次真实设备送达与点击验证使用开发签名包及 Sandbox。Production 的配置和无效令牌拒绝链路已核对，仍未以 TestFlight／正式签名包的有效设备令牌验证真实送达。用户于 2026-10-20 更新验证方式：后续跳过真机测试，由用户亲自验证。后续开发跳过真机测试。本次只执行自动化和模拟器检查，未安装或启动真机，也未发送真机测试通知。上述已完成的实际送达与点击记录作为历史保留，不推定后续版本已完成真机验收。

完整结果索引：[result.json](../experiments/livekit/validation/apns-2026-10-19/result.json)。
