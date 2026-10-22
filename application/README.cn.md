# KikiTalk iOS

[English](README.md) · [仓库总览](../README.cn.md) · [当前架构](../docs/ARCHITECTURE.zh-CN.md) · [项目接手指南](../docs/PROJECT_HANDOVER.zh-CN.md)

用 Xcode 打开 **RTCube.xcworkspace**，选择 **KikiTalk** scheme。最低 iOS 17，支持 iPhone/iPad；工程文件沿用 RTCube 历史名称，当前应用和测试 target 分别为 KikiTalk、KikiTalkTests。

## 依赖与签名

Xcode 通过 Swift Package Manager 解析 LiveKit，工作区的 `xcshareddata/swiftpm/Package.resolved` 记录精确版本。CocoaPods 及腾讯 SDK 配置已移除，不再执行旧 pod 安装或 UserSig 配置步骤。

模拟器沿用工程签名配置，以便访问系统 Keychain；真机选择有权限的开发团队，并核对 Apple 登录、推送通知及后台音频能力。

## 源码分布

| 位置 | 职责 |
| --- | --- |
| `Demo/KikiDemoApp.swift`、`KikiDemoRootView.swift` | App 入口、协议/启动/登录门禁和四页签 |
| `Demo/KikiDemoStore.swift` | 共享业务状态、服务编排、会话及退出清理 |
| `Demo/KikiAccountAPIClient.swift` | 访问 kiki.group 的账号和社交 HTTPS 接口 |
| `Demo/KikiAPIClient.swift` | 访问 furby.top 的语聊业务 HTTPS 接口及共享模型 |
| `Demo/KikiRTCService.swift`、`KikiRoomRuntime.swift` | LiveKit 连接、房间/音频生命周期、聊天同步 |
| `Demo/KikiLiveKitRoomView.swift`、`KikiRoom*.swift` | 语聊房 UI 与交互组件 |
| `Demo/KikiSocial*.swift`、`KikiMomentsViews.swift`、`KikiDirectMessages.swift` | 用户/关系、动态/评论、收件箱/私聊 |
| `Demo/KikiProfileView.swift`、`KikiSettingsLayout.swift` | 个人页、账户设置、房间收藏/足迹和安全入口 |
| `Demo/KikiGifts.swift`、`KikiGiftViews.swift` | 体验余额、礼物、装扮和效果 |
| `Demo/KikiLegal*.swift`、`KikiPush.swift`、`KikiStartupPermissions.swift` | 协议确认、通知和启动权限 |
| `Demo/Resources/`、`Demo/Assets.xcassets/` | 礼物、协议副本、品牌等 App 资源 |
| `DemoTests/` | 当前客户端测试，使用 KikiTalk 的 Test action |

`Demo` 文件名属于当前产品源码。旧腾讯 App/广播扩展、组件、参考 target、Pods 和独立 LiveKit 实验客户端均已移除；KikiVoiceOps 管理端继续独立保留在 `../experiments/livekit/admin-ios/`。

## 验证范围

常规测试以本地 fixture 为主。公网服务、真机和媒体集成测试需要显式环境开关及相应凭据，开启前阅读对应测试的约定；跳过集成测试不代表线上行为已通过。本次 iOS 清理不发布后端，也不修改正式协议正文。
