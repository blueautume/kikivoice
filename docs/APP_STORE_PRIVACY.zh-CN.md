# 隐私签署与 App Store 准备记录

> **目录迁移（2026-10-22）：** 当前用户端为 `ios/KikiTalk`，管理端为 `ios/KikiVoiceOps`，均按 Sources/App、Core、Features 与 Tests/Resources/Configuration 组织；原 application/RTCube 和 experiments/livekit/admin-ios 路径只用于识别历史。可点源码链接已映射新位置，旧构建命令和验收仍按原批次阅读。本次未修改正式协议、后端或线上环境。

> **证据位置：** 下文 `output/`、`experiments/livekit/validation/` 的截图和结果为本地归档，未纳入 Git，克隆仓库不会自动取得；保留链接用于追溯当时记录。

> **文档范围更新（2026-10-22）：** 本页保留各日期的隐私实现、发布及待发布记录，不代替当前 App 隐私报告。当前 KikiTalk 使用系统 Apple 登录/APNs 与 SPM LiveKit；旧腾讯组件、RTCubeLab、Pods 和实验客户端已移除。下文腾讯/Kingfisher/SnapKit 及旧归档的清单数量只属于相应历史构建。此次清理不修改正式协议正文、协议版本或线上隐私页面；当前源码入口见[接手指南](PROJECT_HANDOVER.zh-CN.md)。


## 通知内容偏好协议发布（2026-10-22，r13 已部署）

本轮按用户要求将默认推送从固定通用文案改为可显示发送者昵称、私聊文字正文或互动摘要，并提供通知设置“隐藏消息内容”开关。正式文本只调整与这项显示选择及 Apple APNs 处理内容直接相关的段落，不更改其他功能权责、保留期限或图片处理规则；推送不含照片或图片内容，实际预览还受 iOS 设置控制。

版本为 `2026-10-22-r13`，集合 SHA-256 `d4df1fe9c3c9726e236a1fb99f447f8c53770154fa298264f3f1a937644688d3`。生成器现将语聊 shared 副本纳入输出和检查，三份 JSON 字节一致，11 份输出检查通过；两套 API、官网四个当前页与四个 r13 新归档已配套发布，56 份旧归档不变。现有用户需重新确认新版协议，未确认前暂停需要当前授权的业务。该确认不会替代 iOS 通知权限，也不会自动改变已选择的提醒开关。

发布后账号、语聊及官网 72 个文件与预期一致，18 项正常 TLS 公网核验通过；双 API 与 SFU 正常，凭据和 Nginx 未改，两库只读完整性／外键检查通过，账号仅增加预期偏好列。账号 455 项、推送专项 49 项、语聊 461 项通过；iPhone 353 项（9 跳过、0 失败）、iPad 通知专项 40 项通过。Debug 与未签名的 Release device 构建成功，实际 Info 核验为 `1.0.21 (18)`，需要安装新版 App 才有新增的隐藏内容开关和前台文案；本轮未进行真机通知发送验证。基线与 [发布后检查](../output/push-preview-2026-10-22/postdeploy.json) 保存在 [推送预览记录](../output/push-preview-2026-10-22/)（本地生成资料，未纳入 Git），不能代替 App Store 隐私表单核对或真机送达验证。

## 历史：首次私聊额度协议准备（2026-10-20；2026-10-22 已配套发布）

配合无需互关、对方首次回复前最多 5 条的私聊规则，本地协议更新为 `2026-10-20-r12`，集合 SHA-256 为 `4f84e391121cdd11d20929d033bb2623d91c49f9c7a820bc31140ee46d2525ec`。正文明确关注变化不决定私聊权限、清空本人历史不重置首次联系额度，以及服务器最小条数／回复状态的用途和删除边界。私聊正文的 30 天保留规则、双方拉黑和治理权限继续有效。

唯一正文仍为 `legal/documents.json`，原 r11 历史归档保持原文；App、两套本地后端资源及网站生成结果已同步。此段保留当时的本地准备状态；r12 后续已于 2026-10-22 配套发布，见 [私聊发布记录](P1_SOCIAL.zh-CN.md)。当前版本及发布状态以本文 r13 小节为准；协议发布仍需同时更新两套服务与当前网页，并通过动态协议流程重新取得确认。

## 上传 90683 相机用途声明（2026-10-20）

App Store Connect 对 1.0.4（1）报告缺少 `NSCameraUsageDescription`。当前 KikiTalk 仅开放语音，但链接的官方 LiveKit / WebRTC 包仍包含摄像头接口；[LiveKit Swift 文档](https://docs.livekit.io/transport/sdk-platforms/swift/)要求即使不使用摄像头，也提供相应用途说明。用途声明本身不会弹出授权，只有实际调用权限申请或摄像头功能才会触发系统处理。

按用户选择保留官方 SDK，在两种构建配置共用的 `Demo/KikiInfo.plist` 补齐相机用途说明，并保留当前版本未开放视频、不申请或采集图像的明确说明。移除隐私中心原有的摄像头状态查询与不适用于当前语音版本的权限行；业务代码没有新增主动摄像头权限申请或视频采集。无需修改现有协议 r11 的「当前版本不主动申请摄像头」事实，也未替换 SDK 或启用视频。

保留用户设置的营销版本 1.0.5，将 KikiTalk 构建号更新为 2，重新生成归档。构建、最终包用途字符串、权限和资源检查保存在 `experiments/livekit/validation/camera-purpose-2026-10-20/`；本地归档检查不代表 App Store Connect 已重新上传或通过服务端处理，本轮未代为上传。

## 动态协议获取与覆盖安装恢复（2026-10-20）

本轮将协议获取改为服务器动态下发，修复覆盖安装保留旧同意记录后只能看到“更新 App”、无法确认新协议的问题。当前已发布版本为 `2026-10-20-r10`，整组文本 SHA-256 为 `3e3f94a2012bee417242a16c69b800c57547bc006ac9c1385fbbbf5d105462f4`；唯一正文仍为 `legal/documents.json`，历史已发布文本保持归档。

账号服务与语聊服务均提供匿名 `GET /v1/legal/documents`，返回与各自协议校验共用的启动时完整文本快照，并声明 `Cache-Control: no-store`。主 App 从账号服务 `https://kiki.group/v1/legal/documents` 获取 JSON，以原生阅读器展示；请求不带账号令牌、身份标识、Cookie 或推送令牌，不初始化账号与语聊业务。客户端校验结构、版本及全文 hash 后缓存，只有成功取得服务器当前完整文本后才允许点击“同意并继续”。包内文本和已验证缓存只供离线阅读；获取失败显示重试，不再要求通过更新或卸载 App 才能获取新文本。

覆盖安装保留本机确认记录和协议缓存，启动联网核对服务器版本/hash。若仍为已明确同意的同一份文本，恢复原确认状态，无需重复点击；文本变化则展示新全文后要求重新确认，不将旧同意静默改为新版。运行期间发现协议不匹配时，先停止业务并完成退出清理，再获取新文本；撤回待处理期间不重新获取或恢复业务。正在阅读的旧版本在文本更新后关闭，避免展示与确认版本不一致。

本轮已按用户授权完成发布：账号服务 `kiki.group`、语聊服务 `furby.top` 与官网四份当前协议页均已更新至 r10，公网核对版本和 hash 一致，r9 历史页面保留。签名 Release 归档为 `/tmp/KikiTalk-experience-dynamic-legal-20261020.xcarchive`，iPhone「穷奇」和 iPad 均完成覆盖安装并成功启动，未卸载原应用。签名、Apple 登录 entitlement 与随包协议校验通过，发布包不含私钥或测试登录入口。

公网检查确认两个公开协议接口返回完整四份文本、`no-store` 且不设置 Cookie，私有业务接口未认证时返回 401。另用两个临时签名身份和两个真实 LiveKit 客户端完成 16 项生产冒烟检查，覆盖首次体验钻、礼物与装扮、幂等扣款及真实房间连接；结束后已清理临时账号、会话、房间、体验数据和 SFU 房间。**本轮不含本人 Apple 登录与真实麦克风听感验收**。详情见 [公网检查](../experiments/livekit/validation/experience-dynamic-legal-2026-10-20/public-verification.json)、[生产冒烟与清理](../experiments/livekit/validation/experience-dynamic-legal-2026-10-20/experience-smoke.json)及[设备覆盖安装](../experiments/livekit/validation/experience-dynamic-legal-2026-10-20/client-installation.json)。下文各节为先前阶段记录，其中本地固定协议或“更新 App”处理不再代表本轮实现。

> **归档：切换初期说明（2026-10-19）：** 本次语聊将由腾讯迁至自建 LiveKit，Apple 登录仍由独立账号服务负责。当前客户端、服务边界、协议发布与人工验收状态见 [LiveKit 停机切换](LIVEKIT_CUTOVER.zh-CN.md)；本页下文保留 2026-10-17 及更早的历史，不能据此认定新媒体链路或新协议已经发布、真机验收或完成 App Store 提交。

## 登录前权限准备（2026-10-20）

协议升级为 `2026-10-20-r8`，明确首次同意后、Apple 登录前先检查网络再申请系统通知。只在未有系统授权决定时申请；拒绝或请求异常不阻断登录。登录前只做不含账号凭据／Cookie／推送令牌的自有服务健康检查和系统通知询问，不初始化账号／语聊业务、不注册 APNs 或上传 token；实际绑定仍在有效会话与账号提醒开关允许后进行。普通公网联网提示不是局域网权限，是否显示由 iOS 决定；网络失败提供重试，不推断为权限被拒绝。原四份 r7 与更早协议保留归档，设备对新时机只确认新版一次。结果见 [启动权限验证](../experiments/livekit/validation/startup-permissions-2026-10-20/result.json)。

## 首次使用与登录页整理（2026-10-20）

根据实际界面反馈，首次协议改为单一完整页面，去掉弹窗、遮罩和背后重复的阅读页。协议全文仍可在同意前离线打开；“暂不同意”留在同一页面，业务服务继续关闭。登录页仅保留现有图标、简短提示、原生 Apple 登录按钮与底部小字《用户协议》《隐私政策》链接，错误与进度按需展示。正常状态不再展示说明卡片、协议列表、重复确认说明或额外重连按钮；已有会话可通过 Apple 登录重新认证恢复。

这次只调整本地界面，不改 r7 正文、哈希或确认记录，不要求已经确认当前版本的用户重新确认，也无需更新两台服务器。后续真机仍由用户亲自验证，本次自动化与模拟器结果见 [界面整理验证](../experiments/livekit/validation/onboarding-clean-2026-10-20/result.json)。

## 一次确认更新（2026-10-20）

本次协议版本为 `2026-10-19-r7`，仅将原“勾选”的说明调整为首次完整页面一次点击“同意并继续”，同时明确同意协议及本人已满 18 周岁声明。协议仍可在确认前离线完整阅读；拒绝后留在本地阅读页。当前版本确认会保存在本机，正常重启、退出重登、Apple 授权取消或失败不要求重复确认；协议更新或撤回后仍需重新确认，不将旧版本记录静默改成新版。服务端按各账号保存对应版本和文本哈希。r6 及更早已发布文本保持归档。

消息页同时将“通知”聚合入口与私聊会话合并展示；未增加新的数据类别或系统权限。按用户最新要求，后续跳过真机测试，由用户自行验证，本次只执行自动化和模拟器检查。验证与发布结果见 [本次结果](../experiments/livekit/validation/inbox-consent-2026-10-20/result.json)。

## 系统通知更新（2026-10-19）

APNs 本轮协议升级为 `2026-10-19-r6`，说明系统通知授权、设备令牌和随机安装编号、账号绑定、通用载荷、Apple APNs 处理及退出／撤回清理。主 App 隐私清单新增关联账号、仅 App Functionality 用途的 Device ID；不采集硬件序列号、广告标识或通讯录，不用于跟踪。推送令牌和安装标识的具体处理、实际保留和验收以 [APNs 接入记录](APNS.zh-CN.md) 为准。旧 r5 页面作为已发布历史继续保留。

本次只修改本地随包清单和服务协议，未登录或提交 App Store Connect 隐私表单；正式发版时需按实际数据处理同步填写。

## 社区 P1 更新（2026-10-19）

P1 发布时协议为 `2026-10-19-r5`，增加关注、图文动态与互关文字私聊；完整行为和发布验收见 [P1 交付](P1_SOCIAL.zh-CN.md)。随包隐私清单已覆盖关联账号的照片、文字消息、其他用户内容、产品互动；主 App 另声明 Contacts 类别用于站内关注关系图，不表示读取系统通讯录或新增通讯录权限。分类名称参照 [Apple Collected Data Type](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)。仍未登录或修改 App Store Connect 隐私表单。

## 房间诊断更新（2026-10-19）

当前协议资源修订为 `2026-10-19-r4`，新增按公开账号关联的创建、入房失败和房内警告诊断，详细字段、7 天保留、待补报清理及运维查询范围见 [房间诊断](ROOM_DIAGNOSTICS.zh-CN.md)。该修订的发布状态以该诊断记录为准。

App 的 `PrivacyInfo.xcprivacy` 已将 Performance Data 标记为关联身份，并增加关联身份、仅 App Functionality 用途的 Other Diagnostic Data。错误事件中的耗时、技术错误代码、系统及应用版本会与公开账号关联，不能沿用旧聚合质量数据“不关联身份”的口径。未新增广告追踪或商业分析 SDK；未代为更新 App Store Connect 表单。类别取值参照 [Apple Collected Data Type](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)。

日期：2026-10-17。主体：李浩（个人开发者）；公开联系：2114581274@qq.com；产品仅面向18周岁及以上人士。

当前工作区已切换为 **Apple 登录专用版本**，协议升级为 `2026-10-17-r2`。本轮生产切换、旧用户清理、公网验收及本人真机首次Apple授权已完成；下文历史初版验收与本轮记录分别列示。接入合同、服务器环境变量、密钥管理及人工验收见 [Apple 登录说明](APPLE_LOGIN.zh-CN.md)。

## 归档：Apple 登录首版的隐私签署范围（2026-10-17）

本轮实现明确的电子同意记录，不采集手写签名、身份证照片或出生日期。年龄勾选是本人声明，不代表实名认证或经验证的年龄识别。协议签署流程的完成不等于 App Store 或大陆经营资质已审核通过。

1. 首次启动读取本地协议和本地版本记录；确认前不创建业务Store/RTC、恢复业务会话、发起 Apple 登录或请求麦克风/摄像头。拒绝可留在本地阅读页，不强退App。当前版本不再生成或使用 ID 登录的安装绑定凭据。
2. 用户协议、隐私政策、第三方SDK清单、权限说明可离线完整阅读。协议和18+确认默认不勾选；首次登录还需明确确认，服务器不从旧账号或旧版本推定同意。
3. 后端记录账号、协议版本、整组文本SHA-256、成人声明及服务器Unix时间。版本/文本变更不匹配返回428，业务接口与新UserSig签发均阻断；不记录签名图片、IP或额外硬件标识。
4. “我”提供隐私中心、协议长期入口、系统权限说明、服务器确认记录及撤回。撤回停止本地采集、取消进行中的 Apple 授权、移除房间悬浮界面并退出SDK，撤销账号全部业务会话，处理网络失败与异步回调竞争。未确认的撤回仅保留重试所需的现有会话；确认后清除本机 Apple subject、会话及相关结束授权重试凭据。重新使用需重新同意并通过 Apple 授权，不恢复已注销数据。
5. 后端对撤回原请求的令牌摘要提供24小时幂等确认；不允许旧重试吊销后续新会话。摘要定期清理、注销级联删除。撤回与账号注销的效果在界面及政策中分开说明。
6. 账号注销删除自有在线账号、凭据、同意/撤回记录、头像、收藏和历史；关联旧房间结束并匿名化展示记录。Apple 授权另由后台申请撤销，失败保留所需加密令牌及重试元数据，成功即删，最长7天、最多180次；到期未成功会记录错误并清除队列凭据，不能将其表述为第三方已撤销成功。腾讯侧用户、消息和运维备份并不因此全部即时清空，政策已明确联系处理渠道。
7. 当前登录仅使用系统 AuthenticationServices，不请求 Apple 姓名或邮箱，也不读取或提交 Apple 密码。后端验证身份令牌和一次性授权码，仅持久化 Apple subject、加密刷新令牌及授权管理所需记录；身份令牌和访问令牌不落库。系统状态检查、服务端按需每日核验及签名通知处理授权失效；普通退出、隐私撤回、Apple 授权撤销和业务账号注销分别处理。

## 对外地址与版本

| 用途 | 地址 |
| --- | --- |
| Privacy Policy URL | https://kiki.group/privacy/ |
| 用户协议 | https://kiki.group/terms/ |
| SDK信息共享清单 | https://kiki.group/privacy/sdk/ |
| 系统权限说明 | https://kiki.group/privacy/permissions/ |
| 联系方式 | mailto:2114581274@qq.com |
| 本轮待发布版本文本 | https://kiki.group/legal/2026-10-17-r2/privacy/ （其他文档同目录） |
| 既有历史版本文本 | https://kiki.group/legal/2026-10-17/privacy/ （保持原文） |

唯一正文为 `legal/documents.json`，当前隐私政策、用户协议及配套文档版本均为 `2026-10-17-r2`，增加 Apple 身份认证、必要授权凭据、保存与撤销说明，并移除旧 ID 登录规则。`python3 tools/build_legal_documents.py --check` 校验本地资源、后端资源和网页一致；修改必须先升级相应协议版本并保留已接受的历史文本。新旧整组文本哈希不同，旧版同意不能沿用。SHA-256用于关联文本，不等于CA数字签名、个人实名或有法律效力的第三方电子签章服务。本节 URL 是发布配置和待验收目标，不代表本轮网页已经替换上线。

## 归档：腾讯版隐私清单与依赖（2026-10-17）

- KikiTalk App添加自身 `PrivacyInfo.xcprivacy`；UserDefaults仅用于应用本地设置/同意状态，使用CA92.1理由。自有用户、头像、内容、使用记录按功能用途声明，关联身份，不用于追踪。
- Kingfisher由6.3.1升级为7.12.0，SnapKit由5.0.1升级为5.7.1，使用维护者随CocoaPods发布的隐私清单。SDWebImage及腾讯二进制组件已有厂商清单，保留原始文件，不伪造厂商签名或声明。
- 应检查最终Archive内App资源和SDK资源包，不能只检查源码目录存在清单。新版本或功能改变时重新查看Xcode隐私报告；App manifest不能替代SDK自身所需manifest/适用签名。
- 本历史批次的发布目标为 **KikiTalk**。RTCubeLab 当时仅为示例，现已移除；其登录、分析、推送及协议配置不能作为当前产品的验收结果。
- Apple 登录使用 iOS 自带 AuthenticationServices，已加入 `com.apple.developer.applesignin` entitlement；不另行嵌入第三方登录 SDK。Apple 身份服务已列入本轮 SDK/共享清单，不能将系统框架的使用等同于没有外部身份数据处理。

官方依据：[Apple第三方SDK要求](https://developer.apple.com/support/third-party-SDK-requirements/)、[隐私清单](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)、[Kingfisher 7.12.0清单](https://github.com/onevcat/Kingfisher/blob/7.12.0/Sources/PrivacyInfo.xcprivacy)、[SnapKit 5.7.1 Podspec](https://github.com/SnapKit/SnapKit/blob/5.7.1/SnapKit.podspec)。

Apple 登录与删除处理依据：[验证用户](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)、[注销与授权撤销 TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)、[账号变化通知](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)。

## App Store Connect 隐私标签核对依据

以下是当前代码的数据映射，供真实提交时填写。不能直接将本表当作苹果表单，也不能因为SDK文档标注Linked=false，就忽略本应用能够与账号关联的实际情况。

| 已知处理 | 建议核对类别 | 目的与关联 |
| --- | --- | --- |
| Apple开发者范围subject、业务/SDK用户标识、会话摘要、协议记录 | User ID及适用的Other Data | App Functionality，关联账号，无广告追踪；不公开Apple subject，不再处理ID设备绑定登录 |
| 一次性授权码、身份令牌、加密刷新令牌及撤销/通知记录 | 按Apple定义核对适用的User ID / Other Data | 身份验证、授权维护与删除；只在校验时使用身份/访问令牌，按实际保存范围申报，不因加密就默认无需披露 |
| 昵称、简介、公开头像 | Name / Other User Content / Photos or Videos | 用户资料与房间展示，关联账号 |
| 房间标题和文字消息 | Other User Content / Emails or Text Messages等适用项 | 房间功能；腾讯消息按实际保留与关联能力申报 |
| 收藏、最近20房间记录、创建和进房活动 | Product Interaction | 提供个人资料库与房间功能，关联账号 |
| 实时声音、视频与通信诊断 | Audio Data / Photos or Videos / Performance Data / Other Diagnostic Data | 结合最终SDK报告、服务器与腾讯实际保存配置核对，不因“没录制”就默认不处理；只有满足Apple瞬时处理例外时才按例外判断 |
| 设备/系统/网络/IP与SDK诊断标识 | 依据实际字段核对Device ID等适用类别 | 通信与安全用途；本应用不读取硬件序列号，第三方实际字段按最终SDK报告核对 |

当前没有广告追踪、跨应用营销、位置或通讯录权限，没有接入充值、支付、远程Push、AI转写。用户通过邮件提交支持请求时，应按实际收件/保存情况补充支持信息披露。

[Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)要求覆盖自有与第三方数据处理。必须由开发者在App Store Connect根据实际功能、云配置和最终发布包确认，本文未登录或替用户提交苹果后台信息。

## 提交前仍需由运营者落实的具体事项

1. 确认腾讯应用地域、诊断与房间消息保存配置、委托处理条款。自有账号删除后的腾讯资料/消息清理应有可执行流程及处理记录；不要承诺尚未实现的全量即时删除。
2. 为历史运维备份制定并执行保留、到期清理、权利请求处理和恢复时重放删除的流程；当前协议如实披露现状，没有填写虚假的保留天数。
3. 在App Store Connect填写隐私网址、支持联系方式、数据标签、年龄分级与审核账号。仅18+的产品规则不能替代苹果问卷和适用的年龄/未成年人保护要求。
4. 这是语聊/直播UGC应用。已有房主/房管操作与公开邮件渠道不能等同于完整举报、拉黑、内容治理和平台处置系统；这些仍按商业架构清单推进，隐私弹窗不能替代它们。
5. 在 Apple 开发者后台为对应 App ID 配置服务端通知地址 `https://kiki.group/v1/auth/apple/notifications`，并用本人已登录 Apple 账户的真机完成首次授权、昵称、退出重登、注销及系统撤销测试。不能以 mock 签名或公开 challenge 可达代替真实授权码兑换；不需要把 Apple 密码或验证码交给开发者。

[Apple审核规则](https://developer.apple.com/app-store/review/guidelines/)规定隐私政策、联系方式、账号删除和UGC治理等要求；本轮不代为承诺审核通过。大陆适用备案/经营条件应结合真实发布主体及服务类型另行落实。

## 本轮 Apple 版本验证与发布边界

- 后端103项测试通过；iOS39项测试执行完成（1项opt-in跳过，其余通过）。覆盖真实密码学签名验证的本地fixture与HTTP mock，生产无测试身份后门。
- Apple专项覆盖nonce/state、挑战单次消耗、授权码绑定、错误签名/算法/audience/时间拒绝、JWKS轮换节流、加密刷新令牌、授权代并发、通知幂等/乱序、注销远端失败及撤销队列到期。iOS覆盖旧ID会话禁恢复、取消不建账、系统凭据恢复/撤销、网络暂时失败保留有效凭据、隐私撤回中取消授权及离线结束授权重试。
- 用户已在真机完成首次Apple授权并进入昵称页；服务端确认真实授权码兑换、Apple身份、业务会话、加密刷新令牌及当前协议记录正常，昵称已保存。退出重登、注销和系统撤销的完整人工场景仍需分别验收。生产切换、旧用户清理和官网r2发布已完成，实际记录见下节及 Apple 登录说明。
- 后端发布包必须包含 `backend/app/legal_documents.json`，并在切换前配置 Apple 私钥和独立令牌加密密钥；缺失、草稿或正文与哈希不一致会拒绝启动。App、API与官网应同时发布r2，保留旧网页归档。旧 `/v1/auth/id` 已移除，旧ID安装包及其会话不能补签恢复，必须更新并使用 Apple 登录。
- 本轮旧用户在线数据清理应在停止旧服务、完成受限备份并记录精确用户/房间清单后执行；腾讯云管理员权限、套餐删除能力与逐项结果需另行核对。不要将备份恢复到新业务库而自动合并旧账号。

## Apple 版本发布验收（2026-10-17）

- 已将新后端及官网发布到 `https://kiki.group`，四份当前协议与r2留存页哈希一致，旧 `2026-10-17` 留存页未覆盖。
- 清理在线业务库中5个旧账号、23条房间登记、16条历史记录、旧会话和1张头像；清理后业务账号、身份、会话、房间、收藏、历史与头像均为0。保留本次变更恢复备份，不导入新Apple账号。
- 切换备份：`/var/backups/kikitalk/apple-cutover-20261017T040953Z/`，含旧数据、旧程序/运行环境、受限配置与云端待清理清单。腾讯云管理员尚未配置，云用户和云房间未删除，不能宣称全云端清空。
- 公网确认：健康200，旧ID登录404，未认证业务401，缺协议428，伪造Apple授权/重复挑战/伪造通知401；未创建虚构账号。
- iOS真实challenge额外执行1项，通过且未跳过；签名Release归档 `/tmp/KikiTalk-apple-login.xcarchive` 成功，App与描述文件均有Apple entitlement，签名有效，11份隐私清单，随包r2协议哈希一致，无.p8私钥。
- 新版本已安装至连接的iPhone「穷奇」。本人已完成首次真实Apple登录并保存昵称，服务端核对通过；通知接口已上线，开发者后台URL仍需填写。

## 历史记录：隐私签署初版备份与发布

修改前工作区快照：`~/.local/share/kikitalk/backups/before-privacy-20261017-000822`；Git基线：`codex/backup-before-privacy-20261017-000822`。服务器数据一致性备份：`/var/backups/kikitalk/kikitalk-20261016T160829127863Z`（UTC目录名，对应北京时间2026-10-17）。

以下记录对应 `2026-10-17` 初版和当时的ID登录，不适用于当前Apple专用版本。当时旧App缺少同意字段会收到428；原设备会话补签恢复的兼容规则现已移除。

## 历史记录：隐私签署初版验收

- 后端49项测试通过，iOS29项普通测试通过。
- 真实iOS协议撤回与头像/八麦两项联调通过，均删除临时账号；另以公网API验证缺同意428、服务器记录、全会话撤回、幂等及旧请求不影响重新同意后的新会话。
- 官网4个当前协议页面、4个版本留存页面已发布；390宽度无横向溢出，公开主体和邮箱、版本与哈希显示正确。
- 最终unsigned Release归档 `/tmp/KikiTalk-privacy-final-unsigned.xcarchive` 构建成功，检查11份隐私清单均为有效plist，归档内协议资源与canonical完全一致，无旧固定证书或ATS例外。该归档未签名、未上传App Store，正式分发仍需开发者按自己的账号签名提交。
- 当时Debug构建成功并在模拟器查看首次门禁，两个确认默认未勾选，“同意并继续”禁用，完整协议可离线打开；截图位于 `output/privacy/`。
- 当时服务器API及协议网页同时更新并验证运行正常；切换前应用/网页配置快照位于 `/var/backups/kikitalk/before-privacy-config-20261016T162851Z/`，发布前一致性数据副本位于 `/var/backups/kikitalk/kikitalk-20261016T163116661552Z/`。
