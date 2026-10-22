# KikiTalk 项目结构与接手指南

整理日期：2026-10-20。面向准备逐步接手开发和运维的项目所有者。

当前 KikiTalk 由 **iOS 用户客户端、iOS 管理客户端、账号与社交服务、语聊业务服务、LiveKit 媒体服务、静态官网** 组成。两个 Python 后端分别运行在两台主机上；语聊业务 API 与 LiveKit 媒体进程运行在同一台语聊主机上。

项目最初基于腾讯 TUIKit，当前主 App 已切换为 **Apple 登录、自建业务 API、开源 LiveKit 语音**。仓库保留大量腾讯示例、组件、SDK 配置和实验副本，不能把整个仓库中的依赖都当作当前 App 的依赖。尤其要区分腾讯 **TUILiveKit** 与开源 **LiveKit**，它们是不同项目。

本指南描述当前工作区源码。现有部署记录用于说明服务分工；本次没有连接生产主机。主 App 工程当前版本为 **1.0.7（4）**，部分功能与协议变更仍标为本地待发布，不能据此推定现网已经运行相同版本。

## 1 项目全景

| 组成 | 主要代码位置 | 技术栈 | 负责的事情 |
| --- | --- | --- | --- |
| iOS 用户客户端 KikiTalk | `application/Demo/` | Swift、SwiftUI、UIKit、Combine、LiveKit Swift SDK | 语聊、动态、消息、个人页、登录、资料、礼物、通知 |
| iOS 管理客户端 KikiVoiceOps | `experiments/livekit/admin-ios/` | Swift、SwiftUI、系统 Passkey、URLSession | 账号与语聊看板、社区治理、房间问题查询 |
| 账号与社交服务 | `backend/` | Python 3.11+、FastAPI、SQLite、HTTPX | Apple 身份、账号会话、资料、关系、动态、私聊、APNs、运维身份和授权 |
| 语聊业务服务 | `experiments/livekit/backend/` | Python、FastAPI、SQLite、LiveKit Server API、WebSocket | 房间目录、准入、八麦、房内权限、聊天、公告、礼物、拉黑及语聊治理 |
| 实时媒体服务 | 外部 `livekit-server` 二进制；配置在 `experiments/livekit/infra/` | LiveKit Server、Go、WebRTC、Opus、TURN | 音频传输、转发、订阅与网络穿透；SFU 指选择性转发媒体的服务器 |
| 官网与协议页 | `website/dist/`、`legal/` | 静态 HTML、CSS、SVG、Python 生成脚本 | 产品介绍、隐私和用户协议、SDK 与权限说明、运维隐私说明 |

### 服务之间怎样连接

```mermaid
flowchart TB
    User["KikiTalk 用户 App"]
    Ops["KikiVoiceOps 管理 App"]
    Apple["Apple 登录与 APNs"]
    Account["kiki.group 账号与社交 API"]
    AccountDB[("账号 SQLite 与图片文件")]
    Voice["furby.top 语聊业务 API 与信令网关"]
    VoiceDB[("语聊 SQLite")]
    Media["LiveKit Server 音频媒体与 TURN"]
    Web["kiki.group 静态官网与协议页"]
    User -->|"账号会话 HTTPS"| Account
    User -->|"独立语聊会话 HTTPS"| Voice
    User -->|"房间凭证 WSS"| Voice
    User <-->|"WebRTC 音频"| Media
    Ops -->|"Passkey 与运维会话 HTTPS"| Account
    Account <-->|"独立 HMAC 签名的内部 API"| Voice
    Account --> AccountDB
    Voice --> VoiceDB
    Voice -->|"权限与媒体控制"| Media
    Account <-->|"授权核验与推送"| Apple
    User -->|"阅读公开页面"| Web
```

音频不会经过账号服务。语聊业务 API 管理谁能入房、谁能开麦；LiveKit 执行媒体连接和转发。HTTPS/WSS 信令与 WebRTC 音频是不同的通信链路，排查“能进房但听不到声音”时需要分别检查。

## 2 仓库目录地图

仓库根目录为 `/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS`。

```text
TUIKit_iOS/
├── application/
│   ├── RTCube.xcworkspace       日常打开的工作区，选择 KikiTalk scheme
│   ├── RTCube.xcodeproj         用户 App、测试及腾讯参考 target 的构建配置
│   ├── Demo/                   当前 KikiTalk 主业务源码
│   ├── DemoTests/              当前主 App 测试
│   ├── LegacyTencent/          旧腾讯版本实现，供对照
│   ├── RTCube/                 原腾讯示例 App 入口
│   ├── main/ mine/ login/ assembly/  原腾讯示例模块
│   └── Pods/ Podfile Podfile.lock    腾讯参考 target 的 CocoaPods 依赖
├── backend/                    当前账号、社交、APNs、中央运维身份服务
│   ├── app/                    Python 应用
│   ├── tests/                  单元及 API、跨服务测试
│   └── deploy/                 账号服务部署、Nginx、systemd 和配置模板
├── experiments/livekit/
│   ├── backend/                当前正式语聊业务服务
│   ├── admin-ios/              当前独立 iOS 管理 App
│   ├── infra/                  媒体和 API 部署、代理、维护、备份、探针
│   ├── shared/                 跨服务契约、协议副本
│   ├── ios/                    独立 LiveKit 实验 App，非日常主 App
│   ├── vendor/                 腾讯代码参考快照，不参与实验 App 当前构建
│   └── validation/             按功能和日期保存的验收记录
├── live/                       腾讯 TUILiveKit，非当前主 App 的 LiveKit SDK
├── atomic_x/                   腾讯 AtomicX 公共 UI、主题与工具
├── call/                       腾讯 TUICallKit 通话 UI
├── chat/                       腾讯聊天组件和独立示例工程
├── room/                       腾讯会议及多人房间 UI
├── api-example/                腾讯 AtomicXCore API 示例
├── TEBeautyKit/                腾讯美颜相关参考组件
├── TCEffectPlayerKit/          腾讯特效播放器相关参考组件
├── VideoAdvanceExtension/      原腾讯视频能力扩展参考
├── website/dist/               可直接部署的静态官网
├── legal/documents.json        正式主线协议源文件
├── tools/                      协议、礼物、品牌资源和说明材料生成工具
├── docs/                       项目说明及原腾讯生成的 API 文档
├── output/                     截图、构建或资料输出，不是运行时代码入口
└── AGENTS.md                   项目协作及版本递增约定
```

**`experiments/livekit` 的名字仍来自实验阶段，但其中的后端、管理端和基础设施已被正式主线使用。** 日常先关注 `application/Demo`、`backend`、`experiments/livekit/backend`、`experiments/livekit/admin-ios` 和 `infra`；腾讯参考组件可在需要追溯旧实现时再读。

## 3 iOS 用户客户端

### 工程与开发方式

打开 [RTCube.xcworkspace](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcworkspace)，选择 **KikiTalk**，测试 target 为 **KikiTalkTests**。最低 iOS 17，支持 iPhone 和 iPad，工程使用 Swift 5 语言模式；这表示编译设置，不代表必须安装某个旧版 Swift 编译器。

主入口是 [KikiDemoApp.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiDemoApp.swift:4)。虽然文件和编译宏还带有 Demo 字样，它们目前就是主 App 的入口。当前四个页签为“语聊、动态、消息、我”。

界面以 SwiftUI 为主，房间呈现、窗口和浮层等场景使用 UIKit。状态通过 `ObservableObject`、`@Published` 和 Combine 驱动；网络和生命周期逻辑使用 `async/await`、Task、`@MainActor`。HTTP 使用系统 `URLSession`，JSON 使用 `Codable`；本地会话使用 Keychain。

当前主 target 直接用 **Swift Package Manager** 引入 LiveKit。`Podfile` 中的腾讯依赖属于 **RTCubeLab** 参考 target，开发 KikiTalk 主线无需为新增业务再引入这些 Pods。参见 [Podfile](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Podfile:48) 和 [SPM 锁文件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcworkspace/xcshareddata/swiftpm/Package.resolved)。

### 主要业务代码

下列文件均位于 `application/Demo/`。

| 阅读入口 | 主要职责 |
| --- | --- |
| [KikiDemoRootView.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiDemoRootView.swift) | 协议门禁、启动准备、登录和首次昵称、四页签主界面 |
| [KikiDemoStore.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiDemoStore.swift:123) | 主业务状态中心，串起账号、资料、房间、社交、刷新、续租、退出与隐私撤回 |
| [KikiAccountAPIClient.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiAccountAPIClient.swift:16) | 请求 `kiki.group`：Apple 登录、资料、社交、动态、私聊、推送、协议、换取语聊会话 |
| [KikiAPIClient.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiAPIClient.swift:309) | 请求 `furby.top`：房间、麦位、聊天、礼物、收藏、足迹、安全治理；也定义共享模型 |
| [KikiRTCService.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiRTCService.swift:161) | 连接 LiveKit、音轨和麦克风、成员事件、重连、房间呈现和媒体退出 |
| [KikiLiveKitRoomView.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiLiveKitRoomView.swift) | 当前语聊房界面：八麦、成员、消息、公告和房间操作 |
| [KikiRoomRuntime.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiRoomRuntime.swift) | 房间生命周期、聊天同步、音频中断及路由、网络诊断 |
| [KikiSeatRequestSheet.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiSeatRequestSheet.swift) | 举手与上麦审批面板 |
| [KikiRoomMessageInput.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiRoomMessageInput.swift) | 房间输入组件；相关文件处理键盘退出和消息展示 |
| [KikiSocialModels.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiSocialModels.swift)、[KikiSocialViews.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiSocialViews.swift) | 用户主页、关系、消息入口、站内通知、举报及数据模型 |
| [KikiMomentsViews.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiMomentsViews.swift) | 动态、图片、点赞、评论、发布和详情 |
| [KikiDirectMessages.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiDirectMessages.swift)、[KikiInboxConversationRow.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiInboxConversationRow.swift) | 私聊详情和会话行，消息展示及列表操作 |
| [KikiGifts.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiGifts.swift)、[KikiGiftViews.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiGiftViews.swift) | 免费体验钻石、礼物、装饰、赠送与效果播放 |
| [KikiProfileView.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiProfileView.swift)、[KikiSettingsLayout.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiSettingsLayout.swift) | 个人资料、设置、收藏与足迹等 |
| [KikiLegal.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiLegal.swift)、[KikiLegalViews.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiLegalViews.swift) | 协议读取、版本和同意记录、撤回与展示 |
| [KikiPush.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiPush.swift)、[KikiStartupPermissions.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiStartupPermissions.swift) | APNs、系统通知权限、启动网络检查、通知点击导航 |
| [KikiIncidents.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Demo/KikiIncidents.swift) | 建房、入房及运行异常的关联记录和上报 |

Apple 登录使用 AuthenticationServices；音频使用 AVFoundation 和 LiveKit；通知使用 UserNotifications/APNs；图片选择和处理使用 PhotosUI、UIKit、CoreImage、ImageIO 等系统框架。这些系统框架不属于另行下载的第三方开源依赖。

当前开放语音房，视频直播请求在业务层被拒绝。仓库中的视频、美颜、会议与通话组件，不能据此视为当前 KikiTalk 已开放的产品功能。

## 4 iOS 管理客户端

管理 App 是单独的应用，工程为 [KikiVoiceOps.xcworkspace](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/KikiVoiceOps.xcworkspace)，scheme 为 **KikiVoiceOps**，Bundle ID 为 `com.kikitalk.voiceops`。最低 iOS 17，Swift 5 语言模式，当前工程版本为 **1.0（1）**。

它使用 SwiftUI、Foundation、AuthenticationServices、Security/Keychain 和 UIKit 等系统能力，当前没有额外接入腾讯 SDK、LiveKit SDK 或第三方网络库。

| 核心代码 | 职责 |
| --- | --- |
| [KikiVoiceOpsApp.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/KikiVoiceOpsApp.swift) | App 入口、前后台生命周期与后台页面遮罩 |
| [OpsStore.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsStore.swift)、[OpsViews.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsViews.swift) | 管理状态、看板选择和界面 |
| [PasskeyAuthorization.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/PasskeyAuthorization.swift) | 系统通行密钥创建与登录 |
| [OpsIdentityAPI.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsIdentityAPI.swift)、[OpsTransport.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsTransport.swift) | 固定账号域名的管理请求与传输校验 |
| [SessionVault.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/SessionVault.swift)、[VoiceService.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/VoiceService.swift) | Keychain 运维会话、服务和权限模型、请求允许列表 |
| [OpsCommunityView.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsCommunityView.swift)、[OpsModeration.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsModeration.swift) | 语聊举报、限制和社区处置 |
| [OpsSocialModeration.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsSocialModeration.swift) | 账号服务中的动态、私聊等社交治理 |
| [OpsIncidents.swift](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/App/OpsIncidents.swift) | 房间技术问题查询与展示 |

管理 App 统一向 **`kiki.group/admin/v2`** 注册、登录和请求数据。账号服务器保存运维身份、公钥、会话和权限；需要语聊数据时，由账号服务器签名请求 `furby.top`。App 不直接拿运维 Bearer 登录语聊服务器。

权限分为 `account`、`voice` 和 `community`。新注册者默认没有权限，包括第一位注册者；负责人通过账号服务器本地 CLI 授权。账号和语聊看板权限只读，社区权限允许相应治理操作。早期“两个服务各输一个口令”“管理端只有只读功能”的描述已经不适用于完整现状。详见 [运维账户说明](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/OPS_PASSKEYS.zh-CN.md) 与 [社区治理说明](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/P0_COMMUNITY_SAFETY.zh-CN.md)。

## 5 账号与社交服务

### 服务职责和模块

账号服务位于 [backend](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend)，是一个按业务拆分 Python 模块的 FastAPI 应用。入口为 [main.py 中的 create_app](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/main.py:464)，并非为每个模块单独启动进程。

| 模块 | 职责 |
| --- | --- |
| [main.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/main.py) | 配置、数据库、账号与会话、协议、资料、头像、注销、限流、路由装配 |
| [apple_auth.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/apple_auth.py) | Apple JWT 验证、授权码兑换、加密凭据和授权撤销 |
| [voice_bridge.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/voice_bridge.py) | 账号换取语聊会话，退出、撤回与注销的跨服务可靠投递 |
| [social.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/social.py) | 用户公开资料、关注关系、通知、屏蔽策略及拉黑代理 |
| [social_content.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/social_content.py) | 私聊、会话置顶和本人清理、动态、图片、赞评、举报和社交处置 |
| [push.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/push.py) | 直接调用 APNs、设备绑定、持久待发队列、重试和点击解析 |
| [ops_auth.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/ops_auth.py) | 运维 Passkey、会话、权限、授权 CLI、跨服务管理代理 |
| [admin.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/admin.py) | 账号看板、主机资源、证书、服务状态与备份统计 |
| [activity.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/activity.py)、[maintenance.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/maintenance.py) | 活跃统计、备份状态读取 |
| [voice_incidents.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/voice_incidents.py)、[community_content.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/app/community_content.py) | 技术问题转投、基础文字过滤 |

`gifts.py`、`usersig.py` 和部分旧房间 API 属于腾讯兼容实现。根 gifts 仍保留旧版本兼容端点，当前主 App 的礼物请求走语聊服务。正式桥接模式启用时，账号服务不再向主客户端签发腾讯 UserSig；旧房间、收藏和历史入口会要求迁移到语聊服务。表和代码保留不等于现行主 App 仍在使用它们。

### 数据保存在什么地方

当前使用 Python 标准库 `sqlite3`，SQL 直接写在源码里；数据库启用 WAL 与事务。没有在这套实现中使用 ORM、PostgreSQL、Redis 或 Celery。

| 数据类别 | 主要表或文件 |
| --- | --- |
| 用户与 Apple 身份 | `accounts`、`identities`、`apple_*` |
| 账号会话和授权代次 | `sessions`、`session_apple_grants` |
| 协议同意与撤回 | `legal_consent_events`、`legal_withdrawal_receipts` |
| 社交业务 | `social_*`：关系、私聊、动态、图片元数据、赞评、通知、清理水位、举报及处置 |
| 推送 | `push_installations`、`push_devices`、`push_outbox` |
| 运维身份 | `ops_accounts`、`ops_credentials`、`ops_challenges`、`ops_sessions`、`ops_grants`、`ops_audit` |
| 跨服务可靠任务 | `voice_revocation_outbox`、`voice_incident_outbox` |
| 图片文件 | 头像和社交图片存本机磁盘，数据库保存相关引用 |

普通业务 Bearer 在数据库保存哈希；Apple 刷新令牌加密保存。跨服务 outbox 是数据库中的待办队列，用于让远端临时失败的撤销、删除或问题上报稍后重试，并没有另用一套消息队列产品。

账号库拥有社交数据，但**统一个人拉黑关系的权威在语聊服务**。普通社交请求会获取未缓存的签名屏蔽策略；语聊策略接口不可用时，相应社交操作可能返回 503。这是排查“账号登录正常，但动态或私聊打不开”时需要知道的跨服务依赖。

## 6 语聊业务与媒体服务

### 自己维护的语聊业务代码

代码在 [experiments/livekit/backend](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend)。它与根账号后端分别启动、分别存库；业务通过签名内部 API 协作。

| 模块 | 职责 |
| --- | --- |
| [main.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/main.py) | 配置、会话、数据库、房间准入、麦位动作和权限、生命周期、路由与后台任务 |
| [rtc.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/rtc.py) | 封装 LiveKit Server API，创建房间、调整权限、移除成员、发送同步提示 |
| [signal_gateway.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/signal_gateway.py) | 可撤销的 LiveKit 信令入口，核验当前会话、入场代次和权限 |
| [account_bridge.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/account_bridge.py) | 接收账号授权、租约、续期、撤销和注销的签名请求 |
| [seating.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/seating.py) | 排队、持久审批状态、自动补位与麦位整理 |
| [chat.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/chat.py) | 房内文字、递增序号、幂等发送、历史补拉和公告 |
| [room_catalog.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/room_catalog.py) | 目录持久修订与变化提示，供客户端稳定刷新；目录正文由 main 提供 |
| [experience.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/experience.py) | 免费体验钻石、礼物账目、装饰库存和装备、房内礼物事件 |
| [safety.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/safety.py)、[social_policy.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/social_policy.py) | 举报、拉黑、语聊处置、跨服务屏蔽和当前房间策略 |
| [ops_gateway.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/ops_gateway.py)、[admin.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/admin.py) | 验证中央管理签名、运维看板、治理查询和动作 |
| [observability.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/observability.py)、[incidents.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/app/incidents.py) | 连接质量、容量、短期诊断、房间技术问题 |

语聊 SQLite 保存语聊授权、房间、成员、麦位、排队、消息、治理、体验礼物和媒体清理任务等。账号资料由账号服务授权同步而来；语聊服务不负责 Apple 登录，也不保存 Apple 私钥或刷新令牌。

### LiveKit 负责什么

LiveKit Server 是下载运行的外部开源服务，源码本身没有完整放进当前仓库。仓库中的 Python `rtc.py` 是业务封装，不能替代媒体服务器。历史传输验收记录中的服务版本为 **1.13.10**；systemd 配置只引用二进制路径，实际生产二进制版本需在接管主机时另行核对。

当前语聊按 Opus 语音参数运行，业务提供八麦与听众。配置和部署记录使用“最多 4 个活动房间、每房 32 人、全服共 64 个准入名额”，它是准入保护值，不是每房 64 人，也不是满负载音质保证。

房间文字先由 HTTPS API 鉴权和持久化，再经 LiveKit 数据通道通知其他端补拉。消息正文与发送者以 API 为准；丢失同步提示后仍可补拉。私聊和动态走账号服务，和这套房内聊天分开。

当前代码对普通成员断线使用 60 秒宽限，房主为 15 秒；房主超时会结束房间。实验旧文档中的“120 秒、自动转交房主”等属于早期规则。新房间目录、改名等代码还有本地待发布记录，见第 10 节。

### 代理与进程怎样部署

语聊主机上的公开 TCP 443 由 HAProxy 终止 TLS。HTTP/WSS 经 Nginx 转到业务 API；LiveKit 信令 `/rtc` 等路径也先过 API 的信令网关，再到本机媒体服务。TURN/TLS 则由 HAProxy 分流到 LiveKit TURN。

```text
公开 HTTPS / WSS :443
  → HAProxy
  → Nginx 127.0.0.1:8443
  → FastAPI 127.0.0.1:8010
  → 对信令请求：核验权限后转 LiveKit 127.0.0.1:7880

公开 TURN/TLS :443 → HAProxy → LiveKit TURN :5349
音频媒体 → WebRTC UDP/TCP，或需要时经过 TURN 中继
```

业务 API 当前要求 **单 worker**，信令连接注册表和部分协调状态在进程内。当前模板没有 Redis 或 LiveKit 多节点配置，直接增加 Uvicorn workers 或复制整台服务不能视为已完成扩容。关键配置见 [HAProxy](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/infra/haproxy.cfg)、[Nginx](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/infra/furby.top.conf)、[LiveKit 模板](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/infra/livekit.example.yaml)。

## 7 第三方开源项目与依赖

版本来自本地锁文件和 requirements；它们是本项目锁定的版本，不表示上游最新版本。依赖分为当前主线、基础设施、腾讯参考层，阅读时先确认作用范围。

### 当前 iOS 主线

| 项目 | 锁定版本 | 用途 | 许可证线索 |
| --- | --- | --- | --- |
| [LiveKit Swift SDK](https://github.com/livekit/client-sdk-swift) | 2.18.0 | 连接实时语音、成员和音轨事件、数据同步提示 | [Apache 2.0](https://github.com/livekit/client-sdk-swift/blob/2.18.0/LICENSE) |
| [LiveKit WebRTC XCFramework](https://github.com/livekit/webrtc-xcframework) | 150.7871.3 | Swift SDK 间接引入的 WebRTC 媒体底座 | [包装仓库 MIT](https://github.com/livekit/webrtc-xcframework/blob/main/LICENSE)；底层及随包组件另有许可 |
| [LiveKit UniFFI XCFramework](https://github.com/livekit/livekit-uniffi-xcframework) | 0.1.9 | Swift SDK 间接二进制依赖 | [Apache 2.0](https://github.com/livekit/livekit-uniffi-xcframework/blob/main/LICENSE) |

精确解析结果见 [Package.resolved](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcworkspace/xcshareddata/swiftpm/Package.resolved)。管理 App 当前使用系统框架，无额外三方包。

### 两套 Python 后端

完整精确依赖分别在 [账号 requirements.txt](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/requirements.txt) 和 [语聊 requirements.txt](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/requirements.txt)。主要开源项目如下。

| 项目 | 锁定版本 | 使用范围与作用 |
| --- | --- | --- |
| FastAPI | 0.119.0 | 两端 API 框架，项目为 [MIT](https://github.com/fastapi/fastapi/blob/master/LICENSE) |
| Uvicorn | 0.37.0 | 两端 ASGI 服务进程 |
| Starlette | 0.48.0 | 两端 HTTP/ASGI 基础 |
| Pydantic / pydantic-core | 2.14.1 / 2.50.1 | 两端请求模型与字段校验 |
| HTTPX | 0.28.1 | 账号服务调用 Apple、APNs 和语聊内部接口；语聊开发测试也使用 |
| Pillow | 12.3.0 | 账号端头像、动态图片处理；资源工具也使用图像处理能力 |
| PyJWT | 2.15.1 | Apple/APNs JWT 与 LiveKit 授权令牌相关处理 |
| cryptography | 50.0.2 | 账号端加密与密码学能力 |
| webauthn | 3.0.1 | 账号端运维 Passkey 验证 |
| livekit-api / livekit-protocol | 1.2.2 / 1.1.27 | 语聊端调用媒体 Server API 和处理协议消息 |
| aiohttp | 3.14.5 | 语聊端异步 HTTP、WebSocket 和信令代理 |
| protobuf | 7.36.2 | 语聊端 LiveKit 协议编解码 |
| wsproto | 1.3.2 | 语聊 API 的 WebSocket 协议实现 |
| pytest | 8.4.2 | 两端开发测试，非独立生产服务 |

requirements 还锁定如下支撑包，后续升级应一起检查对应依赖关系：

- 两端共有：`annotated-types`、`typing-extensions`、`typing-inspection`、`anyio`、`idna`、`click`、`h11`。
- 账号端 HTTP/2 和认证支撑：`h2`、`hpack`、`hyperframe`、`cbor2`、`pyasn1`、`pyasn1-modules`、`pyOpenSSL`。
- 语聊端异步与协议支撑：`aiohappyeyeballs`、`aiosignal`、`attrs`、`frozenlist`、`multidict`、`propcache`、`yarl`、`types-protobuf`。

### 媒体和基础设施

| 项目 | 作用 |
| --- | --- |
| [LiveKit Server](https://github.com/livekit/livekit) | 实时媒体 SFU 与内置 TURN；项目使用 [Apache 2.0](https://github.com/livekit/livekit/blob/master/LICENSE)，历史验收版本 1.13.10 |
| SQLite | 两端本机事务数据库，通过 Python 标准库使用 |
| Nginx | 账号 HTTPS 和静态网站、两端 HTTP/WSS 反向代理 |
| HAProxy | 语聊 TLS 入口，区分 HTTP/WSS 与 TURN/TLS |
| OpenSSL | TLS 与部署证书工具链 |
| Linux / systemd | 服务进程、权限隔离、重启与维护定时任务；语聊部署说明记录 Ubuntu 24.04 |

Apple 登录、APNs、系统 Passkey、开发者签名和域名证书属于外部平台或系统服务，不能算作仓库自有代码。当前媒体按自建 LiveKit 部署配置运行。

### 腾讯参考工程仍保留的依赖

以下版本来自 [application/Podfile.lock](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Podfile.lock)，属于原组件及 RTCubeLab 参考层，并非当前 KikiTalk 主 target 的全量清单。

| 项目 | 版本 | 原来的用途 |
| --- | --- | --- |
| Alamofire | 5.0.0 | HTTP 网络 |
| SnapKit / Masonry | 5.7.1 / 1.1.0 | Swift / Objective-C 自动布局 |
| Kingfisher / SDWebImage | 7.12.0 / 5.21.7 | 图片下载、缓存和显示 |
| Toast-Swift | 5.1.1 | 提示 |
| MJRefresh | 3.7.5 | 下拉刷新 |
| JXPagingView / JXSegmentedView | 2.1.2 / 1.3.0 | 分页与分段导航 |
| AtomicX / TUILiveKit / TUIChatKit | 各 1.0.0 | 腾讯公共 UI、直播语聊 UI、聊天 UI，本地 podspec 标为 MIT |
| TUIRoomKit | 4.0.0 | 腾讯会议 UI，本地 podspec 标为 MIT |
| TUICallKit_Swift | 1.0.0 | 腾讯通话 UI，本地 podspec 标为 Proprietary |
| AtomicXCore / RTCRoomEngine | 4.3.10 / 4.3.10 | 腾讯场景核心和房间引擎 |
| TXLiteAVSDK_Professional | 13.4.21067 | 腾讯音视频 SDK，含原 ReplayKit 扩展依赖 |
| TXIMSDK_Plus_iOS_XCFramework / TUICore | 9.0.7662 / 9.0.7660 | 腾讯 IM 与组件基础 |
| AlbumPicker / AlbumPickerCore、RTCCommon | 1.0.8 / 1.0.8、1.3.6 | 原相册组件及腾讯示例公共能力 |

前九个通用库（Alamofire 至 JXSegmentedView）的本地 LICENSE 为 MIT。仓库根 LICENSE 也为 MIT，但腾讯商业引擎与二进制 SDK、各组件自己的许可不能由根 LICENSE 一概覆盖。完整发布时应按实际打入包内的组件保留其许可证和声明；本指南是依赖盘点，不替代发行包的完整依赖及许可清单。

## 8 登录与主要业务调用链

### 普通用户进入语音房

1. App 读取协议、取得同意并完成启动准备。
2. App 向 `kiki.group` 获取 Apple challenge，系统完成 Apple 授权。
3. 账号服务校验 Apple 凭据，创建或恢复业务账号，签发账号会话，App 存入 Keychain。
4. App 调用账号服务 `POST /v1/voice/session`。
5. 账号服务通过独立 HMAC 内部接口向 `furby.top` 换取短期语聊会话。
6. App 用语聊会话查询、创建或加入房间；语聊 API 再返回限定房间的媒体凭证。
7. LiveKit Swift SDK 经信令网关连接媒体服务，服务端依据当前麦位和禁麦状态授予音频权限。

需要分别理解四种凭据：**普通账号会话、语聊会话、LiveKit 房间凭证、运维会话**。它们用途与有效期不同，不能互相替代。账号到语聊的业务 HMAC 与运维聚合 HMAC 也使用不同秘密。

### 修改一项功能通常会涉及哪里

| 想改的功能 | 首先看客户端 | 再看服务端 |
| --- | --- | --- |
| Apple 登录、资料、注销 | RootView、DemoStore、AccountAPIClient、Legal | 根 backend 的 main、apple_auth、voice_bridge |
| 房间列表、建房、改名 | DemoStore、APIClient、CreateRoomView | 语聊 main、room_catalog |
| 麦位、排队、开麦、禁麦 | LiveKitRoomView、RTCService、SeatRequestSheet | 语聊 seating、main、rtc、signal_gateway |
| 房内消息、公告 | RoomRuntime、RTCService、RoomMessageInput | 语聊 chat |
| 动态、私聊、关系 | SocialViews、MomentsViews、DirectMessages、AccountAPIClient | 根 backend 的 social、social_content；屏蔽策略还依赖语聊 social_policy |
| 礼物、免费钻石、装饰 | Gifts、GiftViews、Resources/Gifts | 语聊 experience |
| 系统通知 | Push、StartupPermissions | 根 backend 的 push |
| 管理看板、社区治理 | admin-ios 的 OpsStore、OpsViews 和治理模块 | 根 ops_auth、admin、social_content；语聊 ops_gateway、safety、incidents |

上表为第 3 至第 6 节已链接文件的简称。跨端字段和权限变化时，还应同步契约与测试。

## 9 部署位置与维护入口

以下位置来自仓库部署配置和现有记录；它们用于定位接管对象，不代表本次重新确认过线上健康状态。

| 项目 | 账号主机 | 语聊主机 |
| --- | --- | --- |
| 域名 | `kiki.group` | `furby.top` |
| 记录中的 IP | `43.138.219.160` | `139.224.50.108` |
| 业务程序目录 | `/opt/kikitalk` | `/opt/kiki-livekit-lab/backend` |
| 业务配置 | `/etc/kikitalk/server.env` | `/etc/livekit-lab/api.env` |
| 数据库 | `/var/lib/kikitalk/kikitalk.sqlite3` | `/var/lib/kiki-livekit-lab/lab.sqlite3` |
| API 监听 | `127.0.0.1:8000` | `127.0.0.1:8010` |
| API unit | `kikitalk.service` | `livekit-lab-api.service` |
| 媒体 unit | 无 | `livekit-lab.service` |
| 媒体配置 | 无 | `/etc/livekit-lab/livekit.yaml` |

账号官网部署目录为 `/var/www/kikitalk/current`，通过版本目录和软链切换。头像、社交图片、SQLite 一起参与相应一致性备份；当前维护方案为各主机本机备份，不能由此推定已经有异地容灾。

需要熟悉的维护源码：

- [backend/deploy](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/deploy)：账号服务启动、域名安装及早期部署脚本。`deploy.sh` 执行会修改主机并重启服务；旧 `backup.sh` 只包含数据库和头像，不包含社交图片，不适合作为当前社交数据的完整备份。
- [infra/maintenance](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/infra/maintenance)：后续发布、数据备份、维护任务安装和 APNs 配置。现行 `data_backup.py` 包含社交图片、隔离恢复校验、轮换与状态记录；`install_maintenance.py` 安装相应定时任务。`deploy_p0.py` 的名称来自历史批次，仍包含两端发布逻辑。
- [infra](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/infra)：代理、systemd、媒体配置、容量探针及 smoke 脚本；部分探针会建立业务数据或媒体连接，应读清参数后使用。

主要配置名字包括 `DATABASE_PATH`、`APPLE_CLIENT_ID`、`APPLE_PRIVATE_KEY_PATH`、`APPLE_TOKEN_ENCRYPTION_KEY`、`VOICE_BRIDGE_ENABLED`、`VOICE_AUTH_MODE`、`ACCOUNT_VOICE_BRIDGE_SECRET`、`OPS_BRIDGE_SECRET`、`ADMIN_AUTH_MODE`、`APNS_ENABLED`、`LEGAL_DOCUMENTS_PATH`、`LIVEKIT_API_KEY` 和 `LIVEKIT_API_SECRET`。实际值保存在项目外及服务器受限配置中，不属于 App 资源；正式语聊使用 `account` 模式，运维使用 `passkey` 模式。

`APPLE_TOKEN_ENCRYPTION_KEY` 用于 Apple 刷新令牌和 APNs token 加密，数据库与图片的数据备份不包含这把配置密钥。恢复对应数据库时需要保留匹配的密钥，直接替换新值会使原有加密数据无法解密。

## 10 当前最容易混淆的状态

### 本地代码与现网发布

本地已有“首次回复前最多发 5 条私信”、个人主页和黑名单入口、房间稳定刷新与改名等改动。相关记录中仍有本地待发布标记：

- [社交变更与发布状态](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/P1_SOCIAL.zh-CN.md:124)。
- [房间后续改进与发布状态](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/LIVEKIT_CUTOVER.zh-CN.md:243)。

这些功能需要按对应记录配套更新服务端；不要仅安装新客户端就认定整条链路已更新。当前免费体验礼物和装饰也应与真正的充值、现金收益、提现分开理解，现有代码不代表已经接入真实支付。

### 协议源文件与多个副本

正式主线源文件为 [legal/documents.json](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/legal/documents.json)，[build_legal_documents.py](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/tools/build_legal_documents.py) 生成主 App 资源、账号后端资源和官网当前页及版本归档。

当前本地版本为：

| 位置 | 协议版本 |
| --- | --- |
| 正式源、主 App、账号服务 | `2026-10-20-r12` |
| `experiments/livekit/shared/legal_documents.json` | `2026-10-20-r11` |
| 实验 App 的协议资源 | `2026-10-20-r11` |

语聊后端默认从 `shared/legal_documents.json` 读取，部署可通过 `LEGAL_DOCUMENTS_PATH` 指定。**主线生成脚本不自动覆盖语聊 shared 或实验 App 副本**；其 `--check` 通过也不能证明这些副本已同步。下一次相关发布需要按选定版本同步两端、客户端和网页，并保留已发布的历史协议。

### 历史说明与参考工程

根 README、`application/README`、[旧架构分析](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/ARCHITECTURE.zh-CN.md) 中仍有腾讯、ID 登录或两页签描述。[商业版总体方案](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/COMMERCIAL_ARCHITECTURE.zh-CN.md) 和 [商业模块规划](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/COMMERCIAL_MODULES.zh-CN.md) 是规划资料，不代表所列收费、多端或扩容功能已实现。

实验 App 的邀请码登录只适合明确配置的 `lab` 环境，不能照旧连接已切换 `account` 模式的正式服务。RTCubeLab 及其他腾讯示例属于参考工程，其当前可构建状态应独立验证。

当前工作区包含大量未提交和未跟踪的应用、后端及资料文件，Git 的旧提交不能完整代表本地最新状态。建立接手基线时应一并核对这些文件；清理 `experiments` 或“看起来是生成物”的目录前，先确认是否被当前部署、构建或契约引用。

## 11 建议按这个顺序接手

1. **先运行主 App并认清入口。** 在 Xcode 打开 KikiTalk，先读 App、RootView、DemoStore；把四个页签与代码对应起来。
2. **完整跟一遍登录到入房。** 从 AccountAPIClient 到账号 `main.py`、voice_bridge，再到语聊 account_bridge、main、RTCService。理解各会话与凭证的用途。
3. **选择一个小功能横向阅读。** 比如“修改昵称”或“房间公告”，从页面、Store、API、服务端、SQL 到测试，建立自己的修改路径。
4. **再读语音生命周期。** 重点看开麦权限、断线、后台、最小化、房主离开、隐私撤回和服务端清理。界面关闭与媒体断开是两个需要协调的动作。
5. **接手管理和部署。** 理解 Passkey 身份与权限、两套数据库、图片与备份、单 worker 限制、协议同步和发布记录，再进行独立发布。

### 可以先做的本地检查

下面是学习和后续开发的入口，本次整理没有执行构建、测试、部署或真机操作。

```bash
# 主 App：Xcode 选择 KikiTalk，使用现有签名配置运行或测试
open /Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcworkspace

# 管理 App：选择 KikiVoiceOps
open /Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/admin-ios/KikiVoiceOps.xcworkspace

# 只核对主线协议生成产物，不修改文件
python3 /Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/tools/build_legal_documents.py --check
```

账号和语聊后端各自有 requirements-dev 与 tests。根账号开发依赖额外包含语聊依赖，用于两端 ASGI 契约与生命周期测试。建议在隔离虚拟环境中运行，具体入口见 [账号后端说明](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/README.zh-CN.md) 和 [语聊后端说明](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/backend/README.zh-CN.md)。客户端和管理端测试分别位于各工程的 `DemoTests`、`Tests`；带公网集成开关的用例应按其约定配置，不把跳过集成用例等同于线上通过。

### 进一步阅读

| 主题 | 资料 |
| --- | --- |
| 腾讯切换到自建语音与后续房间改进 | [LIVEKIT_CUTOVER](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/LIVEKIT_CUTOVER.zh-CN.md) |
| Apple 登录 | [APPLE_LOGIN](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/APPLE_LOGIN.zh-CN.md) |
| 中央运维身份与授权 | [OPS_PASSKEYS](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/OPS_PASSKEYS.zh-CN.md) |
| 举报、拉黑、治理与备份 | [P0_COMMUNITY_SAFETY](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/P0_COMMUNITY_SAFETY.zh-CN.md) |
| 关注、动态、私聊与当前待发布改动 | [P1_SOCIAL](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/P1_SOCIAL.zh-CN.md) |
| 免费体验礼物与装饰 | [GIFTS](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/GIFTS.zh-CN.md) |
| APNs | [APNS](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/APNS.zh-CN.md) |
| 房间问题记录和排障 | [ROOM_DIAGNOSTICS](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/docs/ROOM_DIAGNOSTICS.zh-CN.md) |
| 跨服务字段与权限契约 | [shared 目录](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/experiments/livekit/shared)、[账号社交契约](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/backend/social-contract.json) |

shared 中 `account-voice-contract` 描述授权交换；`ops-passkey-contract` 描述运维身份与聚合；`p0-safety-contract` 描述举报和治理；`p1-social-policy-contract` 描述跨服务屏蔽策略；`room-incidents-contract` 描述技术问题记录。旧 `admin-api-contract` 与 `account-admin-api-contract` 仍有被引用的看板数据结构，但其中 v1 口令登录流程属于历史。

本轮仅新增接手说明，没有修改应用功能或修复代码，因此不触发 `AGENTS.md` 的应用版本递增。后续功能或修复应在操作前读取当前版本，并按同一轮只递增一次的约定更新 KikiTalk Debug 与 Release。
