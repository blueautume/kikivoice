# 协议内容与发布

> **资源路径更新（2026-10-22）：** iOS 正文副本已迁至 `ios/KikiTalk/Resources/KikiLegalDocuments.json`，生成器输出定位同步更新。正式源、协议版本、正文、hash与后端/官网内容不因目录移动改变；下文2026-10-17的Pods/腾讯事实与官方参考保留为归档，当前工程见[接手指南](../docs/PROJECT_HANDOVER.zh-CN.md)。

`documents.json` 是应用、后端与官网共用的唯一协议内容源。运营者为李浩（个人开发者），公开邮箱为 2114581274@qq.com，仅向 18 周岁及以上人士开放；这些信息来自本次用户确认。

在仓库根目录执行：

```sh
python3 tools/build_legal_documents.py
python3 tools/build_legal_documents.py --check
```

构建器按 UTF-8 的 `json.dumps(source, sort_keys=True, separators=(',', ':'), ensure_ascii=False)` 结果计算 SHA-256，向生成资源增加顶层 `documentHash`。iOS、账号后端和语聊 shared 的资源字节完全一致；文末保留一个换行，不参与源文档哈希。

输出共 11 份，包括 iOS 本地资源 `ios/KikiTalk/Resources/KikiLegalDocuments.json`、账号后端资源 `backend/app/legal_documents.json`、语聊资源 `experiments/livekit/shared/legal_documents.json`、官网 4 个当前页面与 4 个版本留存页面。`--check` 同时核对三份 JSON 资源和八份当前版本网页；历史留存页不会被新版本覆盖。网站只依赖本站 CSS/SVG，不加载第三方字体、脚本、分析或表单。正文中的 HTTPS 链接仅供用户主动查阅参考规则。

主体、联系邮箱、年龄条件、版本和协议结构缺失，或含常见待填占位词时会终止构建。构建成功仅表示内容结构及资源一致，不等于法律审查、云端配置核验或 App Store 审核已完成。

## 2026-10-23 动态模块下线（r16，已部署）

当前主源、生成物及两端服务/官网均为 **2026-10-23-r16**，集合 SHA-256 为 `44c189c201f28fe97b0e3391dd51d9e30e14b3e044fc8cc8686fa000cec28601`。删除动态、社交图片上传、点赞、评论及相关治理披露，保留资料、头像、关系、文字私信与语聊。历史业务表和私有媒体只作受限回滚保存，旧互动通知不再显示或投递；既有协议归档不变。发布与当前范围见 [关系与私信说明](../docs/P1_SOCIAL.zh-CN.md)。

## 历史：2026-10-23 原生房间背景与 kiki 品牌（r15，已部署）

该批次主源、生成物与当时已部署两端服务为 **2026-10-23-r15**，集合 SHA-256 为 `f1383ed9b580cf4a431e93607d0c4a32af05655f1f1990856777f267ad14f5a0`。软件可见名称统一为 kiki，移除装饰系统披露，仅保留房间五款预设背景的选择及保存说明。账号、语聊、App 资源和官网按同一源同步；既有已发布版本留存不修改。部署状态见 [房间背景说明](../docs/ROOM_BACKGROUNDS.zh-CN.md)。下方 r13 为历史发布记录。

## 2026-10-22 推送内容偏好（r13，已部署）

该批次主源及本地生成物为 `2026-10-22-r13`，文档集合 SHA-256 为 `d4df1fe9c3c9726e236a1fb99f447f8c53770154fa298264f3f1a937644688d3`。仅调整推送内容披露：默认提醒可含发送者昵称、私聊文字正文或互动摘要；在应用通知设置开启“隐藏消息内容”后，之后发送的提醒改用通用文案。推送不包含照片或图片内容，iOS 系统预览设置仍决定设备展示范围。

账号服务、语聊协议资源和官网八个页面已配套发布，56 份旧归档保留。版本和集合 hash 变化会使旧协议确认失效，现有用户需重新确认后恢复业务；不能只更新包内 JSON 或一套服务。11 份资源检查和发布后 18 项正常 TLS 公网核验通过；两套公开完整协议均匹配 r13，官网全部 72 个文件精确匹配本地。`1.0.21 (18)` 的新增应用内开关需安装新版 App，本轮未进行真机通知发送验证。实际发布与只读基线记录见 `output/push-preview-2026-10-22/`（本地生成资料，不纳入 Git），测试和部署摘要见 [系统通知记录](../docs/APNS.zh-CN.md)。

## 版本管理

发布后不得原地修改已经取得用户同意的同版本文本。实质修改应更新对应版本、生效日，生成新页面并保留旧版本目录。`documentHash` 是整组文档集合的校验值，不是数字签名或身份认证；应与版本一并保存在同意记录中。若开发阶段修改同版本草稿，重新生成后需确保三端同时更新；已签署的线上版本不能按该方式覆盖。

## 公开前的真实边界

- 当前在线业务注销会清除本人头像，并将本地旧房间的昵称、头像、原 SDK 用户标识、标题及类别移除或替换为通用内容，保留已结束的房间标识及处理后记录；这不等于腾讯云用户/房间消息和全部历史备份即时清除。不得将当前文本改成“所有数据立即清空”，除非删除流程已经实现并验证。
- 历史运维快照没有统一自动清除周期，腾讯消息/诊断保留参数尚未逐项核实。发布文本如实披露这一点，不填写无法兑现的天数。
- 应实施并记录备份到期清理、按用户清理/到期隔离、恢复时重放删除记录，以及腾讯用户/资料/消息/房间清理和结果跟踪，再据真实配置更新隐私政策。
- 需核验腾讯应用数据地域及相关委托处理条款；如启用录制、内容审核、AI、支付、远程推送或广告，应先更新功能、数据类别和 SDK 清单，依法取得对应授权。
- 版本同意不代替公开头像、声音/画面等具体场景的明确授权，也不代替操作系统权限。
- App Store 隐私标签需按最终归档和服务端实际处理填写，不能直接复制 SDK 清单里的 `Linked=false`，也不能因未录制就完全忽略实时音视频及诊断处理。

## 归档：事实与官方参考（核对日：2026-10-17）

本项目事实依据为 `application/Podfile` 的 KikiTalk 目标、其 Pods 目标配置、`KikiAPIClient`、`KikiDemoStore`、`KikiRTCService`、`KikiProfileView`、`backend/app/main.py` 及部署配置。未读取服务器密钥或应用签名秘密。

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：隐私政策可访问性、目的说明、授权撤回、资料删除和 UGC 要求。
- [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)：关联身份、用户内容、诊断及仅瞬时处理等标签判断边界。
- [Apple 账号删除说明](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion/)：自动创建的账号同样需要应用内发起删除。
- [Apple 第三方 SDK 要求](https://developer.apple.com/support/third-party-SDK-requirements/)：含 Kingfisher、SnapKit、SDWebImage 等组件的隐私清单及适用的二进制签名要求。
- [TRTC 个人信息规则](https://cloud.tencent.com/document/product/647/57574)、[TRTC 合规指南](https://cloud.tencent.com/document/product/647/97575)。
- [RTC Room Engine 个人信息规则](https://cloud.tencent.com/document/product/647/119835)、[合规指南](https://cloud.tencent.com/document/product/647/119836)。
- [TUILiveKit 个人信息规则](https://cloud.tencent.com/document/product/454/125457)：明确沿用 Room Engine 规则。
- [IM 个人信息规则](https://cloud.tencent.com/document/product/269/58094)、[合规指南](https://cloud.tencent.com/document/product/269/97564)。
- [《中华人民共和国个人信息保护法》](https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm)：告知、同意与撤回、必要保存、公开和权利处理等要求。
