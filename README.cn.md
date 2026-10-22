# KikiTalk

[English](README.md) · [iOS 开发入口](application/README.cn.md) · [当前架构](docs/ARCHITECTURE.zh-CN.md) · [项目接手指南](docs/PROJECT_HANDOVER.zh-CN.md)

KikiTalk 是中文 iOS 语聊社区，当前提供 Apple 登录、八麦语聊房、动态、私聊、通知和个人资料。主界面为“语聊、动态、消息、我”四个页签；音频使用自建 LiveKit，账号社交与语聊业务分别由独立后端管理。

## 运行 iOS 应用

1. 用 Xcode 打开 `application/RTCube.xcworkspace`，选择 **KikiTalk** scheme。
2. 等待 Xcode 解析锁定的 Swift Package。最低 iOS 17，支持 iPhone 和 iPad。
3. 模拟器沿用工程签名配置；真机选择有权限的开发团队和设备。

工程及工作区仍保留 `RTCube` 文件名，当前应用 target 为 KikiTalk，测试 target 为 KikiTalkTests。依赖通过 Swift Package Manager 管理，不再需要 CocoaPods 或腾讯 SDK 配置。

## 项目分布

| 目录 | 当前职责 |
| --- | --- |
| `application/Demo/` | KikiTalk 用户客户端 SwiftUI/UIKit 源码 |
| `application/DemoTests/` | 客户端回归及显式开启的集成检查 |
| `backend/` | 账号、社交、APNs、中央运维身份 |
| `experiments/livekit/backend/` | 正式语聊业务 API 与 LiveKit 信令网关 |
| `experiments/livekit/admin-ios/` | 独立 KikiVoiceOps 运维和社区管理 App |
| `experiments/livekit/infra/` | 媒体/API 部署配置、维护、备份与探针 |
| `experiments/livekit/shared/` | 跨服务契约及语聊协议副本 |
| `experiments/livekit/validation/` | 本地生成验收证据，未纳入 Git |
| `website/dist/`、`legal/`、`tools/` | 官网、协议源文件与生成工具 |
| `docs/` | 当前架构、接手指南和分批交付记录 |

`experiments/livekit` 沿用历史目录名，其中后端、管理端、基础设施和契约仍为当前产品服务。2026-10-22 iOS 清理已移除独立实验 iOS 副本、腾讯组件/示例、旧 target、CocoaPods 配置及 vendor 快照。

## 服务分工

- `https://kiki.group`：Apple 认证、资料、社交内容、APNs、协议确认和运维身份。
- `https://furby.top` / `wss://furby.top`：语聊授权、房间、麦位、房内消息、礼物/装扮和 LiveKit 信令/媒体。

账号、语聊、房间和运维凭据分别使用。客户端接收服务端签发的凭证，服务签名密钥不进入 App。

后端启动与部署分别参见[账号服务](backend/README.zh-CN.md)、[语聊服务](experiments/livekit/backend/README.zh-CN.md)和[管理 App](experiments/livekit/admin-ios/README.zh-CN.md)。历史交付记录只描述其对应批次，不代表当前环境已重新部署或完成相同验收。文中 `output/`、`experiments/livekit/validation/` 链接指本地证据，这些目录未纳入 Git，克隆仓库不会自动取得。

项目最初源自 Tencent TUIKit_iOS，保留源码和资源仍遵守相应许可；当前 iOS 已使用 LiveKit 替代原腾讯实现。
