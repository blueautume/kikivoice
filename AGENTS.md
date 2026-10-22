# 项目协作约定

## KikiTalk 版本自动迭代

用户要求：后续修改应用时自动升级版本号，无需再次询问。

- 每轮 KikiTalk 功能修改或问题修复完成后，自动将 `MARKETING_VERSION` 的补丁位加一，并将 `CURRENT_PROJECT_VERSION` 加一。同一轮多文件改动、修复及重试只递增一次。
- 操作前读取工程当前值，保留用户最新设置；用户明确指定版本时以其要求为准。
- 同步更新 `application/RTCube.xcodeproj/project.pbxproj` 中 KikiTalk 目标的 Debug 与 Release 配置。
- 打包后核对实际 App 的 `CFBundleShortVersionString` 和 `CFBundleVersion`，在交付说明中报告最终版本。
- 此约定针对 KikiTalk 应用目标，不自动修改仓库内其他示例目标的版本。

记录此约定时的应用版本为 `1.0.5 (2)`；若期间没有其他版本调整，下一轮应用修改应升级为 `1.0.6 (3)`。
