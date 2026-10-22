# iOS 工程

两个 App 均为 iOS 17+、支持 iPhone/iPad 的独立工程；应用容器、Bundle ID 和凭据各自独立。

| App | 工作区 / Scheme | 说明 |
| --- | --- | --- |
| KikiTalk | [KikiTalk/KikiTalk.xcworkspace](KikiTalk/KikiTalk.xcworkspace) / KikiTalk | [中文](KikiTalk/README.cn.md) · [English](KikiTalk/README.md) |
| KikiVoiceOps | [KikiVoiceOps/KikiVoiceOps.xcworkspace](KikiVoiceOps/KikiVoiceOps.xcworkspace) / KikiVoiceOps | [管理端说明](KikiVoiceOps/README.zh-CN.md) |

## 共同目录约定

```text
AppProject/
├── Sources/
│   ├── App/             应用入口、导航与应用级状态
│   ├── Core/            网络、存储、安全、诊断或设计基础
│   └── Features/        按业务功能组织页面、模型及服务
├── Tests/               对应模块测试与 Integration
├── Resources/           Assets、PrivacyInfo、正文/图片等包资源
├── Configuration/       Info.plist、entitlements
└── Scripts/             仅管理端：工程和图标生成脚本
```

目录对应源文件职责，均编译在各自 App target 中，没有为每个目录新增 Swift package。KikiTalk 使用 SPM LiveKit；KikiVoiceOps 仅使用系统框架。应用版本、Bundle ID、签名和资源打包规则由各自 Xcode 工程管理。

KikiTalk 的 AppStore 保留业务状态与服务编排，RootView 保留门禁和导航；调色板、头像、房间模型、大厅及房间辅助视图等完整顶层类型已独立成文件。部分功能文件仍包含多个页面或状态逻辑，本轮目录整理没有把全部大文件改成细粒度模块。

2026-10-22 已将原 `application/` 及 `experiments/livekit/admin-ios/` 迁入此目录，并将用户工程名 RTCube 改为 KikiTalk。后端、infra/shared、正式协议和官网不随 iOS 移动。总体分工见[当前架构](../docs/ARCHITECTURE.zh-CN.md)和[接手指南](../docs/PROJECT_HANDOVER.zh-CN.md)。
