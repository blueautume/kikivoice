# kiki 当前架构

更新日期：2026-10-23。本文描述整理后的源码与构建入口；完整后端、部署和历史状态见[项目接手指南](PROJECT_HANDOVER.zh-CN.md)。目录移动不代表重新部署或运行验收。

用户端可见名称为 kiki，工程与运行标识仍沿用 KikiTalk。启动只展示图标和名称，协议核对静默进行；仅需新同意时显示签署页面。房间背景包含五款自绘原生渐变，随系统深浅色模式变化，由房主在创建或编辑时选择。当前发布范围和回滚记录见[房间背景说明](ROOM_BACKGROUNDS.zh-CN.md)。

## 工程与目录

| 位置 | 职责 |
| --- | --- |
| `ios/KikiTalk/KikiTalk.xcworkspace` / `KikiTalk.xcodeproj` | kiki 用户 App 和 KikiTalkTests，选择 KikiTalk scheme |
| `ios/KikiVoiceOps/KikiVoiceOps.xcworkspace` | 独立管理 App，选择 KikiVoiceOps scheme |
| `ios/KikiTalk/Sources/`、`ios/KikiVoiceOps/Sources/` | 各自 App/Core/Features 源码 |
| 两个 App 各自的 `Tests/`、`Resources/`、`Configuration/` | 回归、包内资源、Info 与 entitlements |
| `ios/KikiVoiceOps/Scripts/` | 管理工程与图标生成脚本 |
| `backend/` | 账号、社交、APNs、中央运维身份与跨服务授权 |
| `experiments/livekit/backend/` | 正式语聊业务 API、信令网关、房间/麦位、聊天、背景风格 |
| `experiments/livekit/infra/`、`shared/` | LiveKit/API 部署、维护、备份、探针，以及跨服务契约和语聊协议副本 |
| `legal/`、`website/dist/`、`tools/` | 正式协议源文件、官网与资源生成工具 |

两个 App 最低 iOS 17。用户端使用 SwiftUI/UIKit、Combine、URLSession、Codable、Keychain 和 SPM LiveKit；锁定 SDK 版本为 2.18.0，间接依赖以工作区 Package.resolved 为准。管理端使用系统框架，Bundle ID、容器和会话与用户端独立。

2026-10-22 已移除旧腾讯组件/示例、旧 target/Pods、LegacyTencent、独立实验客户端和 vendor，并把两个当前 App 统一到 `ios/`。旧 application/RTCube 入口已更名为 KikiTalk 工程；后端、infra/shared 沿用原路径，运行标识及正式协议不因文件整理改变。

## iOS 目录设计

```text
ios/
├── KikiTalk/
│   ├── Sources/
│   │   ├── App/                  App入口、Root、AppStore、启动准备
│   │   ├── Core/
│   │   │   ├── Networking/       两个HTTPS客户端、重定向策略
│   │   │   ├── Storage/          身份存储与Keychain
│   │   │   ├── DesignSystem/     调色板、头像
│   │   │   ├── Notifications/    APNs和通知路由
│   │   │   └── Diagnostics/      故障关联/上报
│   │   └── Features/
│   │       ├── Authentication/   Apple授权与登录
│   │       ├── Privacy/          协议、同意与撤回
│   │       ├── VoiceRooms/       Models/Discovery/Services/Views/Presentation/Chat
│   │       ├── Social/           用户、关系与站内通知
│   │       ├── Messaging/        私聊、会话与未读
│   │       └── Profile/          资料与设置
│   ├── Tests/                    App/Core/Features/Integration
│   ├── Resources/                Assets、协议、启动页、隐私清单
│   └── Configuration/            Info.plist、entitlements
└── KikiVoiceOps/
    ├── Sources/
    │   ├── App/                  管理App入口和状态
    │   ├── Core/                 Networking/Security/Models
    │   └── Features/             Dashboard/Community/Diagnostics
    ├── Tests/                    Authentication/Dashboard/Community/Diagnostics/Integration/Fixtures
    ├── Resources/                管理图标与隐私清单
    ├── Configuration/            Info.plist、entitlements
    └── Scripts/                  工程及图标生成器
```

分组按职责和业务功能组织，源文件仍编译在各自 App target 中，没有因目录增加新的库或运行进程。Tests 按相应功能分组；管理端两份 dashboard JSON 是测试 bundle 资源。

## 用户端主要文件

以下均相对 `ios/KikiTalk/Sources/`。

| 入口文件 | 职责 |
| --- | --- |
| `App/KikiTalkApp.swift`、`KikiRootView.swift` | App/通知代理入口、协议/启动/登录/昵称门禁、三页签与导航 |
| `App/KikiAppStore.swift`、`KikiStartupPermissions.swift` | 跨页业务状态与服务编排、会话/租约/退出、启动准备 |
| `Core/Networking/KikiAccountAPIClient.swift` | kiki.group 账号/社交、头像、协议、推送及换取语聊授权 |
| `Core/Networking/KikiAPIClient.swift`、`KikiHTTPSDelegate.swift` | furby.top 房间/聊天/安全接口与共享 DTO，HTTPS 重定向策略 |
| `Core/Storage/KikiIdentityStorage.swift` | 身份存储接口、Keychain实现 |
| `Core/DesignSystem/KikiPalette.swift`、`KikiAvatar.swift` | 共用颜色、头像绘制/加载 |
| `Core/Notifications/KikiPush.swift`、`Core/Diagnostics/KikiIncidents.swift` | APNs登记/点击导航、业务/请求/媒体故障关联 |
| `Features/VoiceRooms/Models/KikiRoom.swift` | 房间数据与标题规则 |
| `Features/VoiceRooms/Discovery/` | 大厅、房间封面、建房按钮与表单 |
| `Features/VoiceRooms/Services/` | RTCService、RoomRuntime：LiveKit、音轨、权限、重连、消息同步 |
| `Features/VoiceRooms/Views/` | 房间主界面、上麦审批、公告与诊断辅助视图 |
| `Features/VoiceRooms/Presentation/`、`Chat/` | UIKit房间host、悬浮恢复、消息展示/输入与键盘 |
| `Features/Social/` | 关系/通知模型及页面 |
| `Features/Messaging/` | 私聊详情、会话行和未读请求门禁 |
| `Features/Authentication/`、`Privacy/` | 原生Apple授权、登录/首次昵称、协议校验/确认/撤回 |
| `Features/Profile/` | 个人资料、设置、收藏/足迹、注销与安全入口 |

AppStore 保留跨页面业务状态和服务编排，RootView 保留门禁与导航。已从原集中文件中抽出调色板、头像、身份存储、HTTPS delegate、房间模型、大厅/封面、未读门禁、房间host、公告和诊断视图等完整顶层类型。Social、Profile、网络 DTO 和部分测试仍有多职责集中；本轮未将所有大文件完全拆解。

`Resources/Assets.xcassets` 存品牌图标和启动配色。未上传头像时，KikiAvatar 与语聊悬浮窗使用 iOS SF Symbols 的 `person.crop.circle.fill`，颜色随深浅色模式变化；编辑头像仅支持用户从相册上传照片。房间预设背景的五款索引由语聊服务保存，客户端随深浅色模式绘制（见 [房间背景](ROOM_BACKGROUNDS.zh-CN.md)）；协议 JSON、PrivacyInfo 和启动页继续按原包内资源名加载；`Configuration` 只改变工程定位，不改变 Bundle ID、Keychain namespace 或服务域名。

## 状态与服务流

```text
SwiftUI / UIKit 页面
    ↓ 调用与观察
KikiAppStore / KikiConsentStore / KikiPushController / KikiGiftStore
    ↓
Account API Client       Voice API Client       KikiRTCService
    ↓                         ↓                       ↓
kiki.group                furby.top             LiveKit 媒体
```

ObservableObject 保存跨页和会话级状态，页面 `@State` 保存分页、输入、加载及弹窗。部分 View 仍编排异步请求和重试；网络文件也包含 DTO，因此目录分类不等于已经完全分离 ViewModel 的 MVVM。

社交请求由 store 检查登录、协议和昵称，并在返回时校验会话代次与隐私 revision。退出、撤回或拉黑后，旧请求不能恢复私人内容；页面用 generation/revision 排除旧结果。私信草稿、待确认发送和准入在 store，消息分页与滚动在 View；不确定写入使用原 requestID 幂等重试。

| 链路 | 凭据与职责 |
| --- | --- |
| 用户 App → `https://kiki.group` | 账号 bearer；Apple、资料、社交、协议、APNs |
| 用户 App → `https://furby.top` | 独立语聊会话；房间、麦位、消息与安全 |
| 用户 App → `wss://furby.top` / WebRTC | 指定房间凭证，经信令网关核验后连接LiveKit |
| 管理 App → `https://kiki.group/admin/v2/` | 独立Passkey运维会话与逐项授权 |
| 账号服务 ↔ 语聊服务 | 独立签名内部API，授权交换、撤销、屏蔽及管理代理 |

账号服务不转发音频。业务 API 决定准入/角色/发布权限，LiveKit 执行媒体；房内文字正文来自 HTTPS 权威接口，媒体数据事件仅作同步提示。签名密钥不进入客户端。

## 测试与历史记录

用户端测试在 `ios/KikiTalk/Tests`，管理端测试在 `ios/KikiVoiceOps/Tests`，后端仍各有独立 tests。公网Apple challenge、真实媒体与设备检查需要显式条件，跳过不能记为通过。

[切换记录](LIVEKIT_CUTOVER.zh-CN.md)、[旧腾讯版说明](KIKI_DEMO.zh-CN.md)和规划保留原日期背景/验收，旧路径已注明迁移。当前开发从本页、[iOS导航](../ios/README.md)与[接手指南](PROJECT_HANDOVER.zh-CN.md)进入；历史成功不能替代整理后的构建/现网验证。历史链接的 `output/`、`experiments/livekit/validation/` 是未纳入Git的本地证据，克隆仓库不会自动取得。
