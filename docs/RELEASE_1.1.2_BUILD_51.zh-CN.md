# KikiTalk 1.1.2（51）关系标签修复

日期：2026-11-13。开发分支为 `codex/kiki-bilingual`。保持营销版本 `1.1.2`，Debug、Release 构建号均从 `50` 升至 `51`，本轮只递增一次。

## 修改范围

- 八字“合冲并见”显示为两字“合冲”，星座“相邻星座”显示为“相邻”，解决紧凑图例被省略的问题。
- 图例、当前配对、全部关系说明和无障碍名称共用本地化映射，名称一致。服务端旧标签仍兼容，关系分类及计算不变。
- 图例允许最多 5% 的轻微文字缩放，修复部分屏宽下 MBTI 四字名称仅差 1pt 被省略的问题；保留原名称和现有布局。
- 英文资源逐字节保持不变。房间画布、圆环、曲线、选择器位置及键盘交互均未修改。

## 验证

- 最终模拟器专项 **30 项全部通过，0 失败、0 跳过**：关系舞台 21 项，本地化 9 项。
- 新增旧服务端标签到短名称的回归，覆盖图例、当前配对及关系说明；校验八字和星座图例在 284—440pt 内容宽度完整容纳文字。已有英文图例字宽、三种模式、人数与重排测试一并通过。
- 人工检查 375pt、430pt 的八字和星座截图，以及当前配对/关系说明、430pt 的 MBTI 四字图例；短名称完整，无省略号。本轮未进行真机安装验收。
- 本地化生成器 `--check` 和 `git diff --check` 通过。
- 最终归档 `KikiTalk-1.1.2-51-final.xcarchive` 的实际 App 为 **1.1.2（51）**、Bundle ID `com.kikitalk.demo`。严格签名校验通过，两套打包语言资源与源码一致，关系舞台编译对象晚于最终源码。
- 最终包的布尔值 `ITSAppUsesNonExemptEncryption = NO` 已通过发布预检，沿用已确认的不含法国分发范围。

日志、结果包、49 张测试截图及核验 JSON 位于 `output/short-labels-1.1.2-51-2026-11-13/`。最终验证文件为 `ios-tests-final.log`、`KikiTalk-tests-final.xcresult`、`archive-final.log`、`archive-verification.json` 和 `test-verification.json`。较早的测试/归档保留作诊断记录，不作为最终上传包。

## 发布范围

本轮仅发布 iOS 客户端，需要安装新版 App 生效。未部署后端、官网或协议资源，未操作陪玩管理台服务。“赛博算命”参考项目未修改。原有其他项目的 53 个未提交文件保留内容与权限，不纳入本轮提交或发布。

## TestFlight

已上传 Kiki语聊（App ID `6823355150`），版本 **1.1.2（51）**。2026-11-13 22:26:42（北京时间），Xcode 返回 `Uploaded package is processing.`、`Upload succeeded.`、`Uploaded KikiTalk` 和 `EXPORT SUCCEEDED`，命令退出码 **0**。Apple 已接收并开始处理；账号界面的加密合规及 TestFlight 可下载状态尚未核实，上传成功不代表已可安装。

上传包含两项现有供应商 dSYM 警告（`LiveKitWebRTC.framework`、`RustLiveKitUniFFI.framework`），未阻断上传，本轮未更换这些依赖。回执保存在 `testflight-upload.log`，核验信息见 `testflight-verification.json`。
