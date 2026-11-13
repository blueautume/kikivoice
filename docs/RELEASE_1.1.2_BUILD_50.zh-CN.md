# KikiTalk 1.1.2（50）中英双语发布记录

日期：2026-11-13。已先将 `3ee81733` 快进合并并推送到 `main`，再建立 `codex/kiki-bilingual` 开发双语。本轮保持营销版本 `1.1.2`，构建号仅从 `49` 升至 `50`，修复和重试未额外递增。

## 交付范围

- 英文显示名为 **kikitalk**。界面提供跟随系统、简体中文、English；设置位于“我 → 设置 → 语言”，同意协议前也可切换。中文语言变体使用简体中文，未支持的系统语言回退英文。切换不重建登录和房间会话。
- 整理并翻译 **1,061 条基础词条**，另含 **7 类英文单数形式**。覆盖登录、导航、房间与麦位、三套关系与说明、资料录入、个人主页、社交、私聊、错误、系统通知、权限说明和应用显示名。完整范围与维护方式见 [BILINGUAL.zh-CN.md](BILINGUAL.zh-CN.md)。
- 英文以自然产品表达为目标，统一术语并复核长说明。普通按钮可换行，大字体资料操作改纵排，设置标题在无障碍字号独占整行；修复 Notifications、Language 的末尾孤行。房间仍固定布局，132pt 选择器维持右下角，图例使用短标签，星座根据空间选择全名或常见简称。
- 出生地目录仅显示英文名称或无声调拼音，地区 ID、坐标和原始出生资料不变。昵称、房名、简介、私信、公告和自由填写内容保留原文；系统通知按事件种类生成英文，避免翻译人名或漏译嵌入姓名的提示。
- Apple 登录、系统权限等 iOS 原生界面由 iOS 管理语言；已另在明确英文的测试宿主中验收。App Store 商品页本地化元数据不在本次修改范围。

## 协议与服务端

四份英文法律文本共 **27 节、78 段**，完整对应现有中文版本。canonical 协议仍为 `2026-11-13-r18`，哈希 `8c5a9e483ac385d555d53f1a83a273b6d3c238cd0df281342e88691eb8607743` 未变，不因翻译要求已有用户重新同意。英文 `renderingHash` 为 `ae0eef9a87bd5a985925f7487aff4a98d842ebaca1f77cfbc410db7e970578a2`，通过 `sourceDocumentHash` 绑定原文；缺少匹配英文时不能在英文模式确认同意。

账号与语聊服务新增公开、无凭据的 `/v1/legal/documents/en`，中文 endpoint 和原同意凭据保持兼容。当前 r18 直接复用已校验的随包英文，不额外增加同意前请求。英文政策网页位于 `/en/privacy/`、`/en/terms/`、`/en/privacy/permissions/`、`/en/privacy/sdk/`，同时保留版本归档。

推送语言按每个安装登记，语言切换后更新绑定；独立 `push_device_languages` 表保持旧 `push_devices` 的 12 列和旧版服务回滚兼容。系统摘要可翻译，人名和私信原文不变。服务端排盘、真太阳时及配对分类算法未改，八字原始资料仍仅本人可见，其他人只看到关系结果。“赛博算命”参考项目未修改。

## 验证结果

| 验证 | 结果 |
| --- | --- |
| iPhone 完整回归 | 382 项：374 通过、8 跳过、0 失败 |
| 受影响的关注、互关、私信和资料操作回归 | 14 项全部通过 |
| iPad 双语专项 | 52 项：49 通过、3 跳过、0 失败 |
| 最终英文单复数及小屏大字补验 | 10 项全部通过 |
| 最终英文系统、真实软件键盘专项 | 3 项全部通过 |
| 账号服务完整 pytest | 471 项通过 |
| 语聊服务完整 pytest | 459 项通过 |
| 最后通知模板修补相关 pytest | 89 项通过 |

完整回归通过后仅补充英文单复数形式；最终英文数量规则和设置布局以 10 项补验、英文系统以 3 项重验，均未重复累计到完整回归总数。8 项完整回归跳过包括 4 项当前运行时未提供公开无障碍容器的界面检查，以及需要明确启用或注入凭据的 4 项真实服务集成；未进行真实设备安装或真实账号多人通话。

已检查 320pt 压力宽度、375pt 小屏、430pt 手机、iPad、横屏、大字体与深浅色截图。关系舞台覆盖 1—8 席、长昵称、十二星座字宽、图例宽度和重排避让。原生键盘测试校验主画布固定、输入与发送升降、收起恢复、长输入与控件命中。

客户端日志、结果包、截图和核验数据位于 `output/bilingual-1.1.2-50-2026-11-13/`。主要日志为 `ios-full-final.log`、`ios-regressions.log`、`ios-ipad.log`、`ios-plurals-final.log`、`ios-native-english-final.log`；计数见 `test-verification.json`。后端三次 pytest 输出保存在子任务工具会话 `76683`、`13363`、`63306`，未另落原始日志文件；使用 `backend/.venv/bin/python`。两套资源生成器 `--check`、部署预检、Swift/Python 语法及差异检查均通过。

最终上传归档为 `KikiTalk-1.1.2-50-release.xcarchive`。实际版本 **1.1.2（50）**，Bundle ID 为 `com.kikitalk.demo`，声明 `zh-Hans`、`en`。严格签名校验通过；两套语言资源、单数形式、两份协议与源码一致；71 项生产输入哈希保持不变，36 个修改过的 Swift 编译对象已核对晚于最终源码。详见 `archive-release-verification.json`。

## 实际服务发布

已通过 `deploy_kiki_only.py` 发布账号 API（含每安装推送语言及英文政策站点）与语聊 API（含英文协议和语言相关提示）。分别核验 123、19 项资源与线上一致；两服务均 active，公网健康正常，中文协议哈希及英文全文、四个英文网页均与发布内容一致。

部署保留凭据与业务数据及回滚版本，不改 Nginx 或维护配置、不 reload Nginx；陪玩管理台 `batty-club.service` 的进程状态、PID、启动时间、版本指针、配置哈希和健康在部署前后一致。回滚目录分别为 `/root/kiki-only-releases/20261113T073432573536Z/previous`、`/root/kiki-only-releases/20261113T073433658658Z/previous`。结果见 `deploy-account.log`、`deploy-voice.log`、`online-verification.json`。

原有其他项目的 53 个未提交文件保持内容和权限，不纳入本轮发布或提交。客户端双语与布局需要安装新版 App 生效。

## TestFlight

已上传 Kiki语聊（App ID `6823355150`），版本 **1.1.2（50）**。2026-11-13 16:01:20（北京时间），Xcode 返回 `Uploaded package is processing.`、`Upload succeeded.`、`Uploaded KikiTalk` 和 `EXPORT SUCCEEDED`，命令退出码 **0**。Apple 已接收并开始处理，尚未核实 TestFlight 可下载状态。

上传有两项现有供应商 dSYM 警告（`LiveKitWebRTC.framework`、`RustLiveKitUniFFI.framework`），没有阻断上传；本轮未更换这些依赖。回执见 `testflight-upload.log`，核验结果见 `testflight-verification.json`。
