# KikiTalk 文档导航

更新日期：2026-10-22。当前源码入口与历史批次资料分开阅读；日期记录中的测试数量、安装结果与服务器状态不自动代表当前版本。历史链接中的 `output/`、`experiments/livekit/validation/` 是未纳入 Git 的本地生成证据，克隆仓库不会自动取得。

## 当前开发入口

- [当前架构](ARCHITECTURE.zh-CN.md)：清理后的工程、模块、依赖与服务分层。
- [项目接手指南](PROJECT_HANDOVER.zh-CN.md)：用户 App、管理 App、两套后端、媒体、部署和数据。
- [iOS 工程导航](../ios/README.md)：用户端 KikiTalk 与管理端 KikiVoiceOps。
- [用户端运行说明](../ios/KikiTalk/README.cn.md)：打开 KikiTalk.xcworkspace，选择 KikiTalk，使用 SPM。
- [账号后端](../backend/README.zh-CN.md)、[语聊后端](../experiments/livekit/backend/README.zh-CN.md)、[运维 App](../ios/KikiVoiceOps/README.zh-CN.md)：各自配置和操作入口。

腾讯 iOS 组件/示例、旧 target/Pods、独立实验 iOS 和 vendor 已移除。两个当前App已统一到 `ios/`；`experiments/livekit` 中当前后端、infra/shared 与本地验收资料继续保留。

## 功能与交付记录

这些文档包含对应功能规则和按日期追加的发布/待发布记录，阅读时核对具体批次：

| 主题 | 文档 |
| --- | --- |
| Apple 登录 | [APPLE_LOGIN](APPLE_LOGIN.zh-CN.md) |
| 自建语音切换及房间改进 | [LIVEKIT_CUTOVER](LIVEKIT_CUTOVER.zh-CN.md) |
| 社交、动态与私聊 | [P1_SOCIAL](P1_SOCIAL.zh-CN.md) |
| 免费体验礼物与装扮 | [GIFTS](GIFTS.zh-CN.md) |
| 推送通知 | [APNS](APNS.zh-CN.md) |
| 运维身份与授权 | [OPS_PASSKEYS](OPS_PASSKEYS.zh-CN.md) |
| 社区治理与维护 | [P0_COMMUNITY_SAFETY](P0_COMMUNITY_SAFETY.zh-CN.md) |
| 房间故障诊断 | [ROOM_DIAGNOSTICS](ROOM_DIAGNOSTICS.zh-CN.md) |
| 协议及 App Store 准备 | [APP_STORE_PRIVACY](APP_STORE_PRIVACY.zh-CN.md) |

## 归档资料

[原腾讯版实现与验收](KIKI_DEMO.zh-CN.md)、[域名迁移记录](DOMAIN_DEPLOYMENT.zh-CN.md)、[LiveKit 独立实验历史](../experiments/livekit/README.zh-CN.md)保留当时的背景。其旧工程路径、SDK 安装命令、服务状态与验收不能作为当前操作步骤。

[商业总体方案](COMMERCIAL_ARCHITECTURE.zh-CN.md)、[模块清单](COMMERCIAL_MODULES.zh-CN.md)、[投资大纲](INVESTOR_OUTLINE.zh-CN.md)和 `commercial/` 为 2026-10-16 规划归档，未因本轮清理重新估算或宣称实现。
