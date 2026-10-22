# KikiTalk iOS

[English](README.md) · [iOS 导航](../README.md) · [仓库总览](../../README.cn.md) · [当前架构](../../docs/ARCHITECTURE.zh-CN.md) · [接手指南](../../docs/PROJECT_HANDOVER.zh-CN.md)

用 Xcode 打开 **KikiTalk.xcworkspace**，选择 **KikiTalk** scheme。最低 iOS 17，支持 iPhone/iPad；测试 target 为 KikiTalkTests。

## 依赖与签名

Xcode 通过 Swift Package Manager 解析 LiveKit，工作区 `xcshareddata/swiftpm/Package.resolved` 记录精确版本。模拟器沿用工程签名配置，以便访问系统 Keychain；真机选择有权限的开发团队和设备。

调整签名时核对 Apple 登录、推送通知及后台音频能力。Info.plist 和 entitlements 位于 `Configuration/`，PrivacyInfo.xcprivacy 作为资源进入 App。

## 源码分布

| 位置 | 职责 |
| --- | --- |
| `Sources/App/` | KikiTalkApp、KikiRootView、KikiAppStore、启动准备 |
| `Sources/Core/Networking/` | 账号/语聊 HTTPS 客户端和重定向策略 |
| `Sources/Core/Storage/` | 身份存储协议与 Keychain 实现 |
| `Sources/Core/DesignSystem/` | 共用调色板及头像绘制 |
| `Sources/Core/Notifications/`、`Diagnostics/` | APNs 登记/路由、故障关联与上报 |
| `Sources/Features/Authentication/`、`Privacy/` | Apple 授权与登录、协议确认和撤回 |
| `Sources/Features/VoiceRooms/` | Models、Discovery、Services、Views、Presentation、Chat |
| `Sources/Features/Gifts/` | 体验余额、礼物队列/效果和装扮 |
| `Sources/Features/Social/`、`Moments/`、`Messaging/` | 用户/关系、动态/评论、收件箱/私聊 |
| `Sources/Features/Profile/` | 资料、设置、房间收藏/足迹和安全入口 |
| `Tests/` | 镜像 App/Core/Features 的回归及显式开启的 Integration |
| `Resources/` | Assets、礼物、协议副本、启动页和隐私清单 |
| `Configuration/` | Info.plist、KikiTalk.entitlements |

AppStore 保留跨页面业务状态和会话编排，RootView 保留门禁与导航。原有调色板、头像、房间模型、大厅、未读门禁及房间辅助视图等完整顶层类型已抽成独立文件。Social、Profile 和部分测试文件仍集中多个职责，本轮没有把所有大文件改造成细粒度模块，也没有为每个目录新建 Swift package。

## 资源工具

仓库根 `tools/` 的生成器已指向本项目 `Resources/`。在仓库根执行 `python3 tools/build_legal_documents.py --check` 只检查协议产物，不修改文件。品牌与礼物生成仍属于明确的资源制作操作；移动目录无需重新生成图片或修改协议正文。

## 验证范围

常规测试以本地 fixture 为主。公网服务、真机和媒体集成测试需要显式环境开关及相应凭据，开启前阅读对应测试约定；跳过不代表线上已通过。2026-10-22 已将原 application/RTCube 入口迁至此处，后端部署与正式协议版本独立管理。

管理端独立保留在 [../KikiVoiceOps](../KikiVoiceOps/README.zh-CN.md)。
