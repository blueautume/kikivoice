# Kiki运维 1.0（2）TestFlight 发布

日期：2026-11-14。用户选择将上一轮已验证的管理端上传 TestFlight，继续使用 **1.0（2）**，未重复升级构建号。功能测试、手机安装及服务器修复见 [11 月 13 日更新记录](OPS_REFRESH_2026-11-13.zh-CN.md)；其中“未上传 TestFlight”是当时状态，本记录补充后续发布结果。

## 上传范围与核验

- 建立独立 App Store Connect 记录“Kiki运维”，App ID `6834521403`、Bundle ID `com.kikitalk.voiceops`、主要语言简体中文、SKU `kiki-voiceops-ios`，采用有限 App 访问权限。未提交公开 App Store 审核。
- 建立“Kiki运维”内部测试群组并启用自动分发，加入用户在页面选中的两个本人账号；未邀请其他人或开放外部测试。TestFlight 资格不改变管理服务的 Passkey 或 ACL。
- 添加专用 TestFlight 导出配置，自动签名且保留版本/构建号；将加密声明预检扩展为支持 `--target KikiVoiceOps`，原用户端默认检查方式保持兼容。
- 管理端仅使用 Apple 系统网络、Keychain、Passkey，补充布尔值 `ITSAppUsesNonExemptEncryption = NO`。依据 [Apple 声明键说明](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption) 与 [系统加密文档要求](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)。
- 补齐 iPad 的倒置竖屏声明，最终包含四种方向且不限制全屏，以满足 [Apple 的 iPad 多任务方向要求](https://developer.apple.com/documentation/uikit/uiviewcontroller/supportedinterfaceorientations)。
- 最终归档为 `KikiVoiceOps-1.0-2-testflight.xcarchive`；包内实际版本 **1.0（2）**、Bundle ID、布尔声明、四方向、`webcredentials:kiki.group` 与严格签名均已核验。与上一轮验证归档相比，38 个程序代码/数据段一致；签名字节随包元数据变化，不将完整可执行文件哈希差异误认为业务代码变化。本次没有修改 Swift 功能代码，也未重复执行此前已通过的功能回归。

## 上传回执

2026-11-14 **02:20:14（北京时间）**，Xcode 返回 `Uploaded package is processing.`、`Upload succeeded.`、`Uploaded KikiVoiceOps`、`EXPORT SUCCEEDED`，命令退出码 **0**，未出现上传警告。

随后在 App Store Connect 账号页面确认：构建 **1.0（2）** 的二进制状态为“已验证”，Bundle ID 正确，“App 使用非豁免类加密”为“否”，分发权限包含 `get-task-allow: false`、`beta-reports-active: true` 及正确 Associated Domains，没有缺少加密声明的手动问卷。内部群组自动包含 1 个构建版本和 2 个测试员；两个用户本人账号均显示“已安装 1.0（2）”，对应 iPad Air（第五代）和 iPhone 15 Plus。此安装状态为账号页面观察结果，本次未通过设备工具安装或操作系统 Passkey/Face ID。

本次仅补充客户端分发元数据，没有再次部署或改动任何服务器；原管理员权限、账号服务、陪玩管理台及其他项目代码不在本次操作范围。原有 53 个未提交文件继续保留。

受限证据目录：`output/ops-testflight-2026-11-14/`，包括最终归档、`archive-final.log`、`archive-verification.json`、`testflight-upload.log`、`testflight-verification.json`、`apple-build-metadata.txt` 和 `apple-build-metadata.png`。
