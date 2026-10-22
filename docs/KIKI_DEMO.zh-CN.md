# 归档：KikiTalk 腾讯版实现与验收

> **证据位置：** 下文 `output/`、`experiments/livekit/validation/` 的截图和结果为本地归档，未纳入 Git，克隆仓库不会自动取得；保留链接用于追溯当时记录。

> **已归档（2026-10-22）：** 下文完整保留原腾讯版本的设计、运行命令、路径和验收，仅供追溯。相关 SDK、Pods、示例 target 及旧实现已从当前 iOS 仓库移除，不能按本文配置或验证当前 App。当前运行入口是 `application/RTCube.xcworkspace` → **KikiTalk**，依赖使用 SPM；详见[当前架构](ARCHITECTURE.zh-CN.md)、[接手指南](PROJECT_HANDOVER.zh-CN.md)和[切换记录](LIVEKIT_CUTOVER.zh-CN.md)。当前动态、私聊与免费体验礼物的状态以对应功能记录为准，本页历史成功数量不继承为新的验收。

## 实现方案

项目使用两层服务：SwiftUI 提供中文双 Tab 首页、Apple 登录、资料与房间入口；现有 TUILiveKit / AtomicXCore 承担真实语聊、直播、麦位、房间消息和互动。业务服务器提供账号、腾讯云 UserSig、资料、房间登记、收藏和浏览历史。客户端不持有腾讯云 SecretKey，也不再生成本地虚构房间或消息。

- **业务服务：** `https://kiki.group`，Nginx 提供公网 HTTPS，反向代理到本机 FastAPI + SQLite + systemd 服务；官网位于同域名首页。
- **身份：** 仅使用系统原生 Apple 登录，服务端校验一次性 challenge、nonce、签名及授权码。首次进入必须设置 1–16 字昵称。业务会话与 Apple 标识存于 Keychain；旧 ID 登录、设备随机密钥及旧会话恢复已移除，不做旧用户迁移。
- **音视频：** 服务器签发 UserSig，客户端完成腾讯云登录后加载真实在线房间。SDK 房间控制创建、加入、主播/观众角色、申请上麦、麦克风、摄像头、成员和弹幕。
- **数据：** 资料、收藏、最近 20 次加入记录和创建的房间保存在服务器；房间在线状态以 SDK 返回的实际列表为准。
- **语言：** 中文界面，取消语言选择；Apple 按钮由系统按设备语言显示。
- **授权管理：** 前台、恢复和重连检查 Apple 凭据状态，服务端支持刷新验证及签名通知，注销时由后台撤销 Apple 授权。密钥、数据清理及真机验收详见 [Apple 登录说明](APPLE_LOGIN.zh-CN.md)。

## 归档：腾讯版运行步骤（已移除）

1. 首次安装依赖：

   ```bash
   cd application
   pod install
   ```

2. 使用 Xcode 打开 **`application/RTCube.xcworkspace`**。真实功能版需要 Pods，请使用 workspace。
3. 选择 **KikiTalk** scheme、iPhone 模拟器或真机，按 `⌘R`。
4. 首次打开先离线阅读协议，主动勾选同意及已满 18 周岁确认；登录页还需单独勾选协议与成年确认，然后点击系统 Apple 登录按钮并确认授权。两台设备联调使用两个不同的 Apple 账户，创建语聊房后另一台设备下拉刷新并加入。
5. 真机首次运行时，在 Signing & Capabilities 中选择自己的开发团队，并允许麦克风/摄像头权限。

最低系统 iOS 17。Keychain 需要正常签名；模拟器使用 Xcode 的本地签名即可，不要给运行构建设置 `CODE_SIGNING_ALLOWED=NO`。Xcode 缺少 Metal Toolchain 时，先安装系统提示的该组件。

当前 SDK 固定为 AtomicXCore / RTCRoomEngine 4.3.10，以支持 Apple Silicon 模拟器。原 RTCubeLab target 和 SDK 参考代码保留；KikiTalk target 只连接语聊/直播所需模块。

## 图标与启动页

![App 图标与启动页预览](images/kiki-brand-preview.png)

品牌标识由紫色渐变、对话气泡和五段声波组成，提供默认、深色和系统着色三套 App 图标。源图均为 1024×1024、不含透明通道的 sRGB PNG，由 Xcode 生成各设备所需尺寸。

原生启动页使用相同的向量标识、深色背景、品牌名及「听见，同频的你」标语，并适配安全区。恢复账号时沿用同一布局，仅在实际等待期间显示进度，不额外延长启动时间。启动页源文件为 `application/Demo/KikiLaunchScreen.storyboard`。

已通过模拟器与真机构建，并在 iPhone 17 Pro 模拟器检查桌面图标和冷启动。上图右侧来自实际原生启动页截图，单独预览见 [启动页截图](images/kiki-launch-screen.png)。

图形源路径保存在 `tools/generate_kiki_brand.swift`，可在仓库根目录重新生成资源：

```bash
swift tools/generate_kiki_brand.swift
```

## 使用流程

新版语聊房实机尺寸预览（模拟器实际运行截图，头像和消息来自专用测试账号）：

![紫色八麦语聊房](images/kiki-voice-room.png)

- **大厅：** 切换语聊/直播，按话题筛选、搜索标题或房主，下拉刷新；只显示真实在线房间，没有在线房间时提供创建入口。房间卡片显示累计观看人次，房内成员以 SDK 实时显示为准。
- **创建：** 在语聊模块创建语聊房，在直播模块创建直播间；点击入口时固定房间类型，表单不再重复选择。输入房名，选择话题和氛围。先向服务器登记，再由 SDK 真正创建房间；失败会显示原因，不插入假房间。
- **直播美颜：** 主播新开直播或重新进入自己的直播间时，在摄像头启动前将磨皮、美白默认设为内置面板的最大档位（9）。开播后可在美颜面板继续手动调整；弹窗返回和悬浮恢复不会重设。
- **加入：** 点击在线房间进入真实 SDK 界面。语聊采用参考图的紫色布局，两行四列共 8 个麦位（包含房主），展示真实听众和头像聊天气泡；支持申请上麦、下麦、静音、锁麦、房主管理、关注和消息。顶部更多操作可退出或结束房间。直播支持主播摄像头及观众观看，浮窗与回到房间沿用 SDK 行为。
- **语聊最小化：** 点击房间右上角的收起按钮，或「更多 → 最小化，继续收听」，全屏聊天室收起为应用内全局悬浮球。可以继续浏览大厅、切换「我」和编辑资料；悬浮球支持拖动、左右吸边与键盘避让，点击即可返回原聊天室，点击同一个房间卡片也可返回。最小化保留房间连接、麦位、静音和聊天记录，上麦时也继续保持当前麦克风状态；若要真正离开，请回到房间选择「离开房间」或「结束语聊」。仍在房间时不能创建或加入另一个房间，房间结束、被踢出或账号退出后自动清除悬浮球。
- **收藏：** 长按大厅房间卡片收藏，在「我 → 我的收藏」查看。已结束的房间保留为记录，再次加入时会检查实际状态。
- **我：** 从相册选择头像或使用预设头像，编辑昵称和多行简介；查看收藏、加入记录、自己的房间。相册只授权所选照片，保存前在本地预览、修正方向并裁成正方形，点击保存后上传 JPEG。服务端再次验证图片、去除元数据并保存 512×512 头像，资料同步音视频用户信息。取消编辑不会上传图片；只修改昵称不会清除已保存的相册头像。
- **账号：** 设置中可退出登录；注销要求输入当前业务 ID 确认，成功后删除服务端账号、会话和个人资料库，并安排 Apple 授权撤销。同一个 Apple 账户再次注册会获得新的业务与音视频身份。

语聊麦位和直播功能使用真实腾讯云服务，按所开通的云产品计费。房内新增自有免费 GIF 礼物：每个账号一次性获赠一亿体验钻石，可赠送五款不同价格和效果的礼物；余额及赠送由业务服务器处理，同房成员可看到动画。“我”中可查看余额，详细说明见 [礼物功能](GIFTS.zh-CN.md)。腾讯云商业礼物、充值、收益结算、KTV 点歌和跨房 PK 入口继续关闭。

当前仅允许通过已验证的 Apple 身份登录，不接受输入业务 ID 换取会话，也不按同名或相同邮箱合并账号。Apple 用户标识不作为公开昵称展示。

## 隐私确认与撤回

- 启动先通过匿名 `GET /v1/legal/documents` 获取服务器当前完整的用户协议、隐私政策、SDK 清单和权限说明，校验正文 hash 后才允许确认同意。随包文本及已验证缓存供离线阅读，不能单独作为确认当前协议的依据；网络失败可重试，不必卸载或更新 App 才能读取新协议。点击“同意并继续”同时确认已满 18 周岁，成年确认属于本人声明，不代表实名或年龄核验；暂不同意可留在阅读页。
- 同意前仅进行不带账号凭据、身份标识或 Cookie 的公开协议获取，不创建业务 Store，不初始化 RTC/IM 和图片下载器，不恢复业务会话、不发起 Apple 授权、不请求业务接口，也不申请麦克风和摄像头权限。完整 JSON 由原生阅读器展示，不使用 WebView；协议更新时关闭旧文本阅读页，避免确认仍在展示的旧版本。
- 本机同意记录仅保存版本、文档 hash、确认时间和处理状态，覆盖安装保留记录与协议缓存。联网核对服务器仍为已确认的相同版本/hash 时无需再次点击；版本或 hash 变化则展示服务器新全文并要求重新确认，不静默沿用旧同意。Apple 登录携带当前协议与成年确认；已有会话在 SDK 登录前向服务器登记核对。业务接口返回协议不匹配时先停止服务并完成清理，再动态获取当前文本供补签；隐私中心分别显示本机确认时间与账号服务器记录。
- 「我 → 隐私中心」长期提供四份协议、系统权限说明、服务器确认记录与撤回入口。昵称、头像及简介保存前说明其公开展示范围；开播授权前解释声音/画面经腾讯云向房间成员提供，系统权限按具体操作申请，相册沿用仅选取指定照片的系统选择器。
- 撤回时立即停止本地采集、收起悬浮球并禁止新业务操作，取消刷新和迟到的重连；分别确认音视频退出与后台全业务会话撤销。失败会保留“撤回待完成”页，允许重试及离线阅读，重启也不会恢复业务。
- 后台已确认的撤回结果会保存在本机待处理记录中；SDK 退出失败时重试不会依赖已经吊销的令牌，进程结束后可完成本地清理。清除会话与 Apple 本机身份，重新使用时重新通过 Apple 授权，不保留旧设备绑定秘密。撤回同意不会自动删除账号；既有「账号设置 → 注销账号」入口保留。

2026-10-20 已发布 r10 动态协议至账号服务、语聊服务与官网，iPhone「穷奇」及 iPad 已完成签名 Release 覆盖安装并启动。公网协议核对和使用临时签名身份、两个真实 LiveKit 客户端的 16 项生产冒烟检查通过，临时数据已清理；本轮不含本人 Apple 登录或真实麦克风听感验收。发布与验证记录见 [动态协议说明](APP_STORE_PRIVACY.zh-CN.md#动态协议获取与覆盖安装恢复2026-10-20)及[执行记录](../experiments/livekit/validation/experience-dynamic-legal-2026-10-20/)。

离线协议资源为 `application/Demo/Resources/KikiLegalDocuments.json`。本 App 的 `PrivacyInfo.xcprivacy` 声明用于功能的账号关联资料与交互数据、无跟踪，以及 UserDefaults 的 CA92.1 理由；厂商 SDK 继续使用各自提供的隐私清单，不能用厂商声明替代应用自身的数据披露。

## 服务与密钥

SSH 私钥已移出下载目录，位于本机 `~/.ssh/kikitalk_server.pem`，权限 `0600`。使用：

```bash
ssh kikitalk-server
```

专用连接配置为 `~/.ssh/kikitalk.conf`，主机公钥固定在 `~/.ssh/kikitalk_known_hosts`。腾讯云凭据仅保存在本机 `~/.config/kikitalk/server.env` 和服务器 `/etc/kikitalk/server.env`，均不加入仓库。

业务数据库在服务器 `/var/lib/kikitalk/kikitalk.sqlite3`，部署目录 `/opt/kikitalk`，服务名 `kikitalk`。部署、备份、API 和证书更新说明见 [服务端说明](../backend/README.zh-CN.md)。

App 通过 `https://kiki.group` 访问业务接口，使用系统公开 CA 信任链、域名和有效期校验，已移除随包固定的旧 IP 证书。服务器证书正常续期无需更新 App，证书私钥只保存在服务器和本机受限部署目录。切换后旧固定 IP 安装包需要更新至此版本。

自定义头像保存于服务器 `/var/lib/kikitalk/avatars`，图片 URL 使用 `https://kiki.group/v1/avatars/` 与随机文件名，供其他房间成员公开读取，不携带 Bearer。个人页与大厅仅接受业务域名的 HTTPS 头像地址；SDK 原生头像的 Kingfisher 下载器同样使用系统 CA 校验。登录与会话刷新会同步当前用户的 SDK 头像地址。替换、改回预设或注销时删除旧头像，备份包含数据库和头像文件。

Info.plist 已移除旧 IP 的 ATS 例外，所有请求遵循系统 ATS 规则。业务 API 和业务头像下载拒绝重定向，防止账号凭据被转发到其他地址或降级至 HTTP。腾讯云音视频与预设头像仍连接腾讯云自身服务。

2026-10-16 域名迁移后，已在 iOS 模拟器通过真实联调：ID 注册登录、首次昵称限制、设置昵称、JPEG 头像上传、刷新资料、业务客户端和 SDK Kingfisher 双头像下载器，以及腾讯云八麦房间的创建与结束。测试确认返回头像使用 `https://kiki.group`，结束后已删除专用测试账号。

## 归档：当时的验证命令

已验证业务 API、资料与收藏持久化，以及两台模拟器使用不同账号完成真实语聊房间的创建、发现、加入和消息收发；主播端已实际收到另一台设备发送的消息。新版 8 麦界面已实测首次昵称、相册选图/预览/上传、房内相册头像、静音、锁麦/解锁、消息气泡，以及访客申请上麦→房主同意→进入第 2 麦位。另一个独立测试完成视频房间在腾讯云上的创建、列表发现与结束，并清理测试账号。视频测试没有生成假画面；摄像头采集及双机音视频效果仍需在真机上联调。无可用摄像头的模拟器会明确提示使用真机开播。

悬浮球独立联调已通过：顶部按钮最小化、球外触摸穿透、非 key 窗口、sheet 上点击与连点恢复同一控制器、8 麦及静音/消息保持、阻止加入其他房间，以及真实房间结束后的悬浮球与状态清理。该验证使用专用随机账号，结束后删除账号和房间数据。

当前 Apple-only 版本 iOS 测试执行 39 项，其中 1 项可选真实 challenge 测试默认跳过，其余通过；后端 103 项通过。此前 ID 版本的双设备、头像、八麦和悬浮球联调属于历史验收，不代表新 Apple 授权已经真机实测。旧 ID 集成测试已移除；`KIKI_TEST_APPLE_CHALLENGE=1` 可验证真实后端挑战且不会创建用户。本人已在签名真机完成首次Apple授权并保存昵称，服务端核对身份、会话和加密刷新令牌正常；退出重登、注销与系统撤销仍需分别人工验收。

```bash
# iOS API 合约与房间模型测试
xcodebuild -workspace application/RTCube.xcworkspace \
  -scheme KikiTalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test

# 服务端行为和权限测试
backend/.venv/bin/python -m pytest -q backend/tests

# 公网 HTTPS 状态
curl --fail https://kiki.group/health
```

## 归档：当时的主要文件

| 文件 | 职责 |
| --- | --- |
| `application/Demo/KikiLoginView.swift` | Apple 系统授权、nonce/state、协议与成年确认、首次昵称 |
| `application/Demo/KikiLegal.swift` | 版本化本机确认、服务器状态与可重试撤回 |
| `application/Demo/KikiLegalViews.swift` | 离线协议、首次门禁与隐私中心 |
| `application/Demo/KikiAPIClient.swift` | HTTPS API、证书校验、Keychain |
| `application/Demo/KikiDemoStore.swift` | 真实登录态、房间列表合并、资料和收藏同步 |
| `application/Demo/KikiRTCService.swift` | SDK 登录、真实房间创建/加入、权限和退出回调 |
| `application/Demo/KikiVoiceRoomFloatingOverlay.swift` | 语聊全局悬浮球、触摸穿透、拖动与键盘避让 |
| `application/Demo/KikiDemoRootView.swift` | 双 Tab 和真实房间大厅 |
| `application/Demo/KikiCreateRoomView.swift` | 创建表单和输入校验 |
| `application/Demo/KikiProfileView.swift` | 资料、记录、退出和注销 |
| `backend/app/main.py` | 账号、会话、资料、房间元数据和个人资料库 API |
| `backend/app/usersig.py` | 腾讯云 UserSig 服务端签发 |
