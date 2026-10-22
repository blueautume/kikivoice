# KikiTalk 当前架构

更新日期：2026-10-22。本文描述清理后的源码与构建入口；完整后端、部署和历史状态见[项目接手指南](PROJECT_HANDOVER.zh-CN.md)。本次文档更新没有连接生产服务，不构成新的部署或运行验收。

## 工程与目录

| 位置 | 职责 |
| --- | --- |
| `application/RTCube.xcworkspace` / `RTCube.xcodeproj` | KikiTalk 用户 App 和 KikiTalkTests；选择 KikiTalk scheme |
| `application/Demo/` | 当前 iOS 用户业务源码、资源与合规清单 |
| `application/DemoTests/` | 当前单元、原生界面 fixture、显式启用的集成测试 |
| `experiments/livekit/admin-ios/` | 独立 KikiVoiceOps 管理 App，系统 Passkey、看板、社区管理 |
| `backend/` | 账号、社交、APNs、中央运维身份与跨服务授权 |
| `experiments/livekit/backend/` | 正式语聊业务 API、信令网关、房间/麦位、聊天、礼物 |
| `experiments/livekit/infra/` | LiveKit 和 API 部署、维护、备份、探针 |
| `experiments/livekit/shared/` | 跨服务契约与语聊协议副本 |
| `legal/`、`website/dist/`、`tools/` | 正式协议源文件、官网及资源生成工具 |

主 App 最低 iOS 17，使用 SwiftUI/UIKit、Combine、URLSession、Codable、Keychain 和 LiveKit Swift SDK。LiveKit 通过 SPM 固定为 2.18.0；间接依赖的精确结果以工作区 `Package.resolved` 为准。管理 App 使用系统框架，工程与用户 App 独立。

2026-10-22 已移除旧腾讯组件与示例 App、RTCubeLab/广播扩展 target、CocoaPods 配置、LegacyTencent、独立实验 iOS 副本和 vendor 快照。工程的 RTCube 文件名、当前源码的 Demo 名称及 `experiments/livekit` 下正式后端的历史命名继续保留。

## 客户端模块

| 入口文件，均位于 `application/Demo/` | 职责 |
| --- | --- |
| `KikiDemoApp.swift` | SwiftUI App 和通知代理入口 |
| `KikiDemoRootView.swift` | 协议、启动准备、登录/昵称门禁；“语聊、动态、消息、我”四页签和大厅 |
| `KikiDemoStore.swift` | 中央状态与业务编排：账号、房间目录、资料、社交汇总、未读、草稿、语聊租约、退出及隐私清理 |
| `KikiAccountAPIClient.swift` | 账号/社交网络接口、公开头像下载与缓存、协议和推送登记 |
| `KikiAPIClient.swift` | 房间/聊天/礼物/安全网络接口，共享用户和房间 DTO、错误、HTTPS 与 Keychain 工具 |
| `KikiRTCService.swift` | LiveKit 连接和音轨、成员事件、麦克风控制、最小化及房间呈现 |
| `KikiRoomRuntime.swift` | 房间生命周期、权威消息补拉、音频中断/路由及质量诊断 |
| `KikiLiveKitRoomView.swift` | 八麦、成员、公告、聊天、房间管理操作 |
| `KikiCreateRoomView.swift`、`KikiCreateRoomButton.swift` | 建房表单与按钮 |
| `KikiSeatRequestSheet.swift`、`KikiRoomMessageInput.swift` | 上麦审批、原生消息/Emoji 输入 |
| `KikiRoomChatPresentation.swift`、`KikiRoomMessageInput.swift`、`KikiRoomKeyboardDismissal.swift` | 聊天呈现、输入和键盘交互 |
| `KikiVoiceRoomFloatingOverlay.swift` | 房间悬浮入口及恢复 |
| `KikiSocialModels.swift` | 用户/关系、动态/评论、通知/会话/私信模型，以及排序、时间线和重试规则 |
| `KikiSocialViews.swift` | 搜索用户、公共主页、关系列表、收件箱、通知和社区举报 |
| `KikiMomentsViews.swift` | 动态图片、卡片、列表、发布、详情/评论与选图处理 |
| `KikiDirectMessages.swift`、`KikiInboxConversationRow.swift` | 私信详情、消息分页/已读、会话列表操作 |
| `KikiProfileView.swift`、`KikiSettingsLayout.swift` | 个人资料、头像编辑、设置、收藏/足迹、注销和安全入口 |
| `KikiLoginView.swift` | 原生 Apple 授权适配、登录按钮/页面与首次昵称 |
| `KikiLegal.swift`、`KikiLegalViews.swift` | 协议校验、同意回执、更新门禁、撤回及阅读界面 |
| `KikiPush.swift`、`KikiStartupPermissions.swift` | 系统通知、APNs 绑定/点击路由、启动网络及权限准备 |
| `KikiGifts.swift`、`KikiGiftViews.swift` | 免费体验钻石、礼物背包/队列、装扮和动画 |
| `KikiIncidents.swift` | 业务操作、网络请求及媒体异常的关联与上报 |

资源包括 `Assets.xcassets` 品牌图标和启动配色、`Resources/Gifts` 礼物、`Resources/KikiLegalDocuments.json` 协议副本，以及 Info.plist、entitlements、PrivacyInfo.xcprivacy 和启动页。应用行为与资源是否进入构建以工程 Sources/Resources 为准。

## 分层与状态流

```text
SwiftUI / UIKit 页面
    ↓ 调用与观察
KikiDemoStore / KikiConsentStore / KikiPushController / KikiGiftStore
    ↓
Account API Client       Voice API Client       KikiRTCService
    ↓                         ↓                       ↓
kiki.group                furby.top             LiveKit 媒体
```

代码按功能文件组织，没有再按 Models/Services/ViewModels/Views 建目录。ObservableObject 保存跨页和会话级状态；页面的 `@State` 保存分页结果、输入、加载、弹窗及请求代次。部分 View 同时编排异步请求和重试；API 文件也包含模型，因此这是中央 store 与功能页面协作的结构，并非严格分离 ViewModel 的 MVVM。

社交请求由 store 统一检查登录、协议和昵称，并在返回时校验会话代次及隐私 revision。退出、撤回或拉黑后，旧请求不能恢复私人内容；页面也用 generation/revision 排除旧结果。私信草稿、待确认发送和准入在 store；已加载消息、分页及滚动在 View。写请求用稳定 requestID 处理结果未确认时的幂等重试。

## 两个服务域与媒体

| 链路 | 账号凭据与职责 |
| --- | --- |
| KikiTalk → `https://kiki.group` | Apple 认证、资料、社交、协议、APNs；账号 bearer |
| KikiTalk → `https://furby.top` | 由账号服务换取的独立语聊会话；房间目录、入房、麦位、消息、礼物与安全 |
| KikiTalk → `wss://furby.top` / WebRTC | 指定房间的媒体凭证，经信令网关核验后连接 LiveKit |
| KikiVoiceOps → `https://kiki.group/admin/v2/` | 独立 Passkey 运维会话与逐项授权 |
| 账号服务 ↔ 语聊服务 | 独立签名内部 API；授权交换、撤销、屏蔽策略及管理代理 |

账号服务不转发音频。业务 API 决定准入、角色及可发布权限，LiveKit 执行媒体连接和转发。房内文字正文来自 HTTPS 权威消息接口，媒体数据事件只用于同步提示；服务签名密钥不进入客户端。

## 测试和历史材料

当前回归位于 `application/DemoTests`；管理端测试在 `experiments/livekit/admin-ios/Tests`，两套后端各有独立 tests。公网 Apple challenge、真实媒体及设备检查需要显式条件，跳过不能记为通过。

[切换记录](LIVEKIT_CUTOVER.zh-CN.md)、[旧腾讯版说明](KIKI_DEMO.zh-CN.md)及商业规划保留对应日期的背景与验收，已经标记历史范围。当前开发从本页、根 README 与[接手指南](PROJECT_HANDOVER.zh-CN.md)进入；历史成功记录不能替代清理后构建或线上重新验收。历史链接中的 `output/`、`experiments/livekit/validation/` 是本地生成资料，已由 .gitignore 排除且未纳入源码提交，克隆仓库不会自动取得。
