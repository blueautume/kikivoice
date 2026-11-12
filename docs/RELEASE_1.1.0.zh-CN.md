# Kiki 1.1.0（46）发布记录

日期：2026-11-13；开发分支：`codex/kiki-development`。按用户要求递增第二段版本并将补丁位归零：`1.0.301（45）` → **`1.1.0（46）`**。Debug、Release 配置一致；本轮不改变麦位关系规则或服务端协议。

## 测试与构建

升级版本前完成账号后端 459 项、语聊后端 456 项全量回归，均无失败及跳过。iOS 全目标执行 353 项，345 项通过，8 项既有环境限定用例跳过，0 失败；日志与 xcresult 位于 `output/release-1.1.0-2026-11-13/`。未安装、启动真实设备，未发送真实账号消息或测试通知。

升级后签名 Release 归档成功，实际 `CFBundleShortVersionString=1.1.0`、`CFBundleVersion=46`、`CFBundleIdentifier=com.kikitalk.demo`，签名严格核验通过；保留相机与麦克风用途声明。TestFlight 使用 `Configuration/ExportOptions-TestFlight.plist` 的 App Store Connect 自动签名上传方式，关闭自动改版本与 Build。App Store Connect 项目为 Kiki语聊（`6823355150`）。

## 服务器发布范围与后验

本轮只增加 iOS 发版配置，未改变服务器运行源码。发布前后逐文件核对：账号服务 22 个源码／数据资源及 Kiki 官网 87 个文件、语聊服务 16 个源码资源及共享协议，均与当前本地完全一致，发布状态为 **already-current**。因此没有重复写入源码、切换官网指针、重启服务、重载共享 Nginx 或重写维护脚本。

两端服务均为 active/running；8 项公网检查通过，包含健康、r17 协议版本及文档哈希一致性，以及私密资料、关系结果、语聊受保护接口对匿名请求的 401 拒绝。账号服务器的新增陪玩管理台作为保护对象，前后对照进程 PID、启动时间、版本指针、unit／Nginx／环境文件／维护脚本哈希、健康接口和首页内容；核验结果与本次输出记录为准。它的代码、配置、进程和业务数据不在本次发布范围内。

完整基线、后验、归档核验和 Apple 上传回执保留于忽略目录 `output/release-1.1.0-2026-11-13/`。原有未提交的其他网站和部署文件保持原样，“赛博算命”项目未修改。

## TestFlight

2026-11-13 01:38:53（北京时间），Xcode 返回 `Upload succeeded`、`Uploaded KikiTalk`、`EXPORT SUCCEEDED`，退出码 0；**1.1.0（46）已上传至 Kiki语聊的 App Store Connect 项目**。网页会话已过期，已提示用户重新登录；Apple 后续处理完成／可供下载状态尚未在页面核验，不将上传成功等同于已可下载。

有两项非阻断符号警告：`LiveKitWebRTC.framework`（UUID `4C4C4483-5555-3144-A179-07B2D85BB81A`）和 `RustLiveKitUniFFI.framework`（UUID `84127E2D-6B37-3011-A1FB-65918C898860`）缺少匹配 dSYM。已核对固定官方 SPM 包及本地归档，未找到可补的供应商原始符号；主 App dSYM 存在。该限制影响两个第三方库的崩溃符号化完整性，不影响上传被接收。未为消除提示更改依赖或重复上传构建。

上传完成后再次核验 Kiki 源码、资源与 8 项公网检查，全部通过；陪玩管理台最终对照为 `unchanged=true`，进程、启动时间、配置、版本指针与首页未变化。具体上传回执及后验 JSON 位于本轮 output 目录。
