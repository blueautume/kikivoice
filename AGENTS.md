# 项目协作约定

## KikiTalk 版本自动迭代

用户最新要求（2026-11-13）：除非用户明确要求调整版本号，后续默认只升级构建号并上传 TestFlight，无需再次询问。

- 每轮 KikiTalk 功能修改或问题修复完成后，保持 `MARKETING_VERSION` 不变，仅将 `CURRENT_PROJECT_VERSION` 加一并按既有流程上传 TestFlight。同一轮多文件改动、修复及重试只递增一次；用户明确指定营销版本或构建号时以其要求为准。
- 操作前读取工程当前值，保留用户最新设置；用户明确指定版本时以其要求为准。
- 同步更新 `ios/KikiTalk/KikiTalk.xcodeproj/project.pbxproj` 中 KikiTalk 目标的 Debug 与 Release 配置。
- 打包后核对实际 App 的 `CFBundleShortVersionString` 和 `CFBundleVersion`，在交付说明中报告最终版本。
- 此约定针对 KikiTalk 应用目标，不自动修改仓库内其他示例目标的版本。

最新规则生效前的版本为 `1.1.2 (48)`；本轮保持 `1.1.2`，构建号升级为 `49`。后续仍应先读取工程实际值，不能按此记录覆盖用户的新设置。

## TestFlight 加密声明

用户要求：后续上传时一并配置加密声明，避免上传后还需手动回答问卷。用户已明确 Kiki 的 App Store 分发范围不包含法国。

- 当前 App 使用 Apple 系统加密功能及 LiveKit/WebRTC 的标准传输加密，没有自研或专有加密；不能将第三方 WebRTC 描述为“仅使用系统 HTTPS”。按当前不含法国的分发范围，`ios/KikiTalk/Configuration/Info.plist` 已配置布尔值 `ITSAppUsesNonExemptEncryption = NO`。
- 下次正常打包前运行 `python3 tools/check_kiki_export_compliance.py`；归档后、上传前运行 `python3 tools/check_kiki_export_compliance.py --app <归档内的 KikiTalk.app 路径>`，核验最终包中存在该声明且类型正确，不能只检查源码。
- 上传后将加密合规状态纳入验收；不能仅凭上传成功就声称 TestFlight 已可安装。若账号访问暂不可用，明确报告尚未核实的状态。
- 如增加专有加密、变更加密依赖/用途，或扩展至法国，先重新核对 Apple 的要求，不能机械保留 `NO`；若需要文档，使用 Apple 批准后提供的真实 `ITSEncryptionExportComplianceCode`，不得填写占位值。
- 本次用户要求下次生效：仅提前配置声明与发布检查，不为此单独增加构建号或重新上传；随下一轮正常发布一起生效。已上传构建的合规状态不会因本地源码修改追溯改变。

依据：[Apple 的声明键说明](https://developer.apple.com/documentation/bundleresources/information-property-list/itsappusesnonexemptencryption)、[标准加密及法国分发的文档要求](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)。

## 服务端发布

用户要求：后续完成修改后，记得将最新服务端代码部署到现有服务器，无需重复询问常规发布。

- 涉及后端、官网或服务端协议资源时，完成相关验证后，检查线上差异、保留回滚版本，再按现有部署流程发布，并核验服务状态及公网健康。
- 仅有 iOS 客户端改动时，明确说明需要安装新版 App 才能生效；不要将客户端代码同步到服务器当作应用发布。
- 部署保留线上凭据和业务数据；涉及不可逆数据变更、目标不明或超出既有发布范围时，先说明具体问题再确认。
- 交付时报告实际部署范围、版本与验证结果，不把本地提交当作已经上线。
