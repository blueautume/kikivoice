# kiki 房间预设背景

更新日期：2026-10-23。本轮删除独立装饰系统；房间只保留五款预设背景。本轮账号、语聊 API 及官网已配套部署，客户端界面需安装本轮新包后生效。

## 客户端和业务协议

五款为“简约、晨光、晴空、暮色、薄荷”。背景随系统深浅色模式渲染，不上传背景素材，不保存个人装饰装备，也不提供头像框、麦位光效或聊天气泡目录。预设索引为 `0...4`，选择在建房表单和房主编辑界面中完成。房间内所有成员统一显示房主保存的背景，没有个人背景切换入口或本地覆盖状态。

- `POST /v1/rooms` 的 `theme` 为严格整数 `0...4`。
- `PATCH /v1/rooms/{id}` 接受 `theme`、`title`，或两项一起；修改仅限房主，返回完整房间状态及权威 revision。
- `status` 必须单独提交，不能与名称或背景编辑混用。
- 房间状态和目录 revision 随实际编辑更新；同值重试不产生额外 revision。
- 历史第六款及其他越界索引读取时返回默认 `0`，不批量改写线上房间数据。

装饰模块、初始化/迁移代码、公开查询路由、选择路由、客户端对应类型和专用验收脚本均已删除。现有服务器中的停用业务表保留在受限数据库和备份中，用于回滚，不再由在线功能访问。管理应用原本没有装饰管理入口；相关礼物、钻石入口已在上一轮移除。

## 原生视觉与参考

背景由 SwiftUI `LinearGradient`、`RadialGradient` 和轻量路径自绘，深浅色模式分别取色；它们是自绘原生渐变，并非拷贝系统壁纸，也不依赖外部壁纸文件。房间、封面和背景选择器共用同一套绘制，文字与系统控件按当前模式适配。

设计参考 Apple 官方 [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) 与 [Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode) 指南。链接用于说明材质及外观适配的参考方向，不表示应用背景为 Apple 提供的壁纸资源。

## 协议与品牌

正式可见名称为小写 `kiki`；Bundle ID、Keychain 名称、服务目录及工程标识延续现有值。官网首页、当前法律页面、运维隐私说明和服务端 API 名称同步。

协议源版本为 `2026-10-23-r15`，集合 SHA-256 为 `f1383ed9b580cf4a431e93607d0c4a32af05655f1f1990856777f267ad14f5a0`。通过 `python3 tools/build_legal_documents.py` 生成 App、账号服务、语聊 shared 和官网当前/归档资源；既有已发布归档不修改。`--check` 的 11 份输出一致性检查通过。

## 本地验证

- 账号服务完整回归：440 项通过。
- 语聊服务完整回归：443 项通过，包含五款背景创建、无效索引拒绝、房主编辑权限、名称与背景原子更新、故障不提交、状态与目录刷新、旧背景兼容以及装饰接口关闭。
- 品牌补扫后的受影响回归：账号 push/开播/Passkey/admin 127 项、语聊 admin/gateway 38 项通过；管理端 iPad ad-hoc 签名完整回归 65 项通过，1 项现有真实公网集成用例按开关跳过。
- 两端发布包与远程脚本通过无网络预检；语聊发布包包含 16 个资源文件（15 个业务源码资源和 1 份独立协议 JSON），账号发布包包含 96 个资源文件（含官网及维护脚本）。

## 实际部署与回滚

2026-10-23 已部署 `furby.top` 语聊 API、`kiki.group` 账号 API 及静态官网。两端服务均恢复 `active` 并通过本机健康检查；发布器逐文件核对语聊 15 个源码资源、账号 16 个源码资源、官网 79 个文件，全部与本地发布内容一致。两端使用同一份 r15 协议版本和文档 hash；LiveKit 媒体节点配置、线上凭据及停用业务数据未改动。

| 范围 | 实际私有回滚目录 |
| --- | --- |
| 语聊 API 与 shared 协议 | `/root/kiki-native-room-releases/20261023T042632551520Z/previous` |
| 账号 API、官网与协议 | `/root/kiki-native-room-releases/20261023T042742669468Z/previous` |

本地发布记录为 [语聊](../output/native-refresh-2026-10-23/deploy-voice.log) 和[账号](../output/native-refresh-2026-10-23/deploy-account.log)，位于不纳入 Git 的交付目录，克隆仓库不自动包含这些记录。管理端可见品牌已同步，签名 Release 包为 `kiki-ops-1.0-1.ipa`，版本 `1.0 (1)`；构建包未自动安装到设备。

后续同范围发布可执行：

```sh
python3 backend/deploy/deploy_native_room_refresh.py voice --check
python3 backend/deploy/deploy_native_room_refresh.py account --check
python3 backend/deploy/deploy_native_room_refresh.py voice
python3 backend/deploy/deploy_native_room_refresh.py account
```

发布器检查进程运行用户，保留私有源代码、环境、网关及旧官网指针，先完成可恢复备份。新源会按生产解释器预导入，再短暂停服替换源码及法律资源；账号端官网采用版本目录和原子软链切换。失败自动恢复源代码、协议和官网指针。私有回滚目录位于 `/root/kiki-native-room-releases/<UTC>/previous`。

发布输出包含源码差异、逐文件哈希核对数量、法律版本/hash、健康与进程状态，以及回滚路径。公网 TLS、完整协议和背景编辑的业务验收由当前交付流程另行记录；源码匹配与服务健康不等于客户端已安装。

## 本轮交付验证

正式公网 30 项验收全部通过：五款背景创建和编辑、访客读取一致、重复保存不增加 revision、越权与非法索引拒绝、旧装饰接口 404、两端协议和官网一致。两名隔离短期身份与五间测试房已清理；数据库与 SFU 活动残留为零。

iOS 本轮共 335 项独立用例通过，3 项既有环境限定用例跳过；初次未签名运行的 Keychain 用例在正确签名后于 iPhone/iPad 均通过。双设备启动、个人页、消息页、创建背景、房间聊天与深浅色截图已核对。Ops 为 65 项通过、1 项既有公网集成用例跳过。两个 Release IPA 的签名、包内版本、ZIP CRC 与可执行权限均已核对。

用户 App：kiki **1.0.34（31）**；管理 App：kiki运维 **1.0（1）**。安装包及完整元数据在仓库 `output/native-refresh-2026-10-23/`，客户端尚未安装，需要安装新版才能看到界面改动。
