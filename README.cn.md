# KikiTalk

[English](README.md) · [iOS 工程导航](ios/README.md) · [当前架构](docs/ARCHITECTURE.zh-CN.md) · [项目接手指南](docs/PROJECT_HANDOVER.zh-CN.md)

KikiTalk 是中文 iOS 语聊社区，提供 Apple 登录、八麦语聊房、动态、私聊、通知和个人资料。主界面为“语聊、动态、消息、我”四个页签；音频使用自建 LiveKit，账号社交与语聊业务由独立后端管理。

## 运行两个 iOS App

| App | 工作区 | Scheme |
| --- | --- | --- |
| KikiTalk 用户端 | `ios/KikiTalk/KikiTalk.xcworkspace` | KikiTalk |
| KikiVoiceOps 管理端 | `ios/KikiVoiceOps/KikiVoiceOps.xcworkspace` | KikiVoiceOps |

用 Xcode 打开相应工作区。两个 App 最低 iOS 17，支持 iPhone/iPad；KikiTalk 通过 Swift Package Manager 解析锁定的 LiveKit，KikiVoiceOps 使用系统框架。模拟器沿用工程签名配置，真机选择有权限的开发团队和设备。

详见[用户端说明](ios/KikiTalk/README.cn.md)和[管理端说明](ios/KikiVoiceOps/README.zh-CN.md)。原 application/RTCube 与实验目录内的管理端已统一到 `ios/`，不再需要 CocoaPods 或腾讯 SDK 配置。

## 项目分布

| 目录 | 当前职责 |
| --- | --- |
| `ios/KikiTalk/` | 用户端；Sources/App、Core、Features，以及 Tests、Resources、Configuration |
| `ios/KikiVoiceOps/` | 独立管理端；沿用相同主结构，另有本地 Scripts |
| `backend/` | 账号、社交、APNs、中央运维身份 |
| `experiments/livekit/backend/` | 正式语聊业务 API 与 LiveKit 信令网关 |
| `experiments/livekit/infra/` | 媒体/API 部署配置、维护、备份与探针 |
| `experiments/livekit/shared/` | 跨服务契约及语聊协议副本 |
| `experiments/livekit/validation/` | 本地生成验收证据，未纳入 Git |
| `website/dist/`、`legal/`、`tools/` | 官网、协议源文件与生成工具 |
| `docs/` | 当前架构、接手指南和分批交付记录 |

`experiments/livekit` 沿用历史名称，其中后端、基础设施和契约仍为当前产品服务。2026-10-22 iOS 清理已移除独立实验客户端、腾讯组件/示例、旧 target、CocoaPods 配置及 vendor 快照。

## 服务分工

- `https://kiki.group`：Apple 认证、资料、社交内容、APNs、协议确认和运维身份。
- `https://furby.top` / `wss://furby.top`：语聊授权、房间、麦位、房内消息、礼物/装扮和 LiveKit 信令/媒体。

账号、语聊、房间和运维凭据分别使用；客户端接收服务端凭证，服务签名密钥不进入 App。

后端配置分别参见[账号服务](backend/README.zh-CN.md)和[语聊服务](experiments/livekit/backend/README.zh-CN.md)。历史交付记录只描述对应批次，不代表当前环境已重新部署或完成相同验收。`output/`、`experiments/livekit/validation/` 链接指未纳入 Git 的本地证据，克隆仓库不会自动取得。

项目最初源自 Tencent TUIKit_iOS，保留源码和资源遵守相应许可；当前 iOS 已使用 LiveKit 替代原腾讯实现。
