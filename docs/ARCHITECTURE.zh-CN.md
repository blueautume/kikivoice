# TUIKit_iOS 项目架构完整拆解

分析日期：2026-10-16

分析基线：main，提交 0758f9ba（本次分析开始时工作区干净）

分析对象：当前仓库的已跟踪源码、Podfile/锁文件、Podspec、Xcode 工程与共享 Scheme

文档用途：项目接手、功能定位、二次开发、问题排查和架构演进

> 本文以当前源码和构建配置为准。已读取四个 Xcode 工程的 target/scheme 配置，未安装或更新依赖，未进行完整编译、真机通话或联网业务验证。文中将“代码事实”“架构判断”“待验证影响”分开描述。AtomicXCore 等外部 SDK 的内部实现不在本次源码分析范围内。

## 阅读导航

1. [整体定位与架构结论](#1-整体定位与架构结论)
2. [工程与目录地图](#2-工程与目录地图)
3. [依赖关系与构建边界](#3-依赖关系与构建边界)
4. [主 App 的启动与鉴权](#4-主-app-的启动与鉴权)
5. [首页装配、导航与模块通信](#5-首页装配导航与模块通信)
6. [状态管理与数据流](#6-状态管理与数据流)
7. [直播与语音房](#7-直播与语音房)
8. [音视频通话](#8-音视频通话)
9. [会议与 Webinar](#9-会议与-webinar)
10. [即时通信](#10-即时通信)
11. [AtomicX 公共 UI 层](#11-atomicx-公共-ui-层)
12. [Demo 与 API 示例的区别](#12-demo-与-api-示例的区别)
13. [横切能力与配置](#13-横切能力与配置)
14. [已发现的问题与维护风险](#14-已发现的问题与维护风险)
15. [需求到代码的定位地图](#15-需求到代码的定位地图)
16. [架构演进建议](#16-架构演进建议)
17. [推荐阅读顺序与验证记录](#17-推荐阅读顺序与验证记录)

## 1. 整体定位与架构结论

### 1.1 这个仓库实际是什么

当前代码是一套腾讯实时互动 UI 组件和示例工程的集合，覆盖聊天、通话、视频直播、语音房、会议等场景。application 是把多个 Kit 组合在一起的综合体验 App；chat 下还有两套独立聊天 App；api-example 则直接演示 AtomicXCore 的 API。

因此，需要区分三个层级：

| 层级 | 当前仓库中的对应物 | 负责什么 |
|---|---|---|
| 运行入口 | RTCubeLab、ChatDemo、ChatDemoMini、AtomicXCoreExample | 窗口、登录、页面导航、体验场景 |
| 可复用组件 | TUILiveKit、TUICallKit_Swift、TUIRoomKit、TUIChatKit、AtomicX | 场景 UI、交互编排、UI 状态与扩展接口 |
| 外部核心能力 | AtomicXCore、RTCRoomEngine、TXLiteAVSDK、IMSDK、TUICore | 业务 Store、媒体能力、消息通信、组件基础设施 |

AtomicX 和 AtomicXCore 是不同的模块：前者在本仓库中主要提供 UI、主题和工具；后者是通过 CocoaPods 引入的核心 SDK。根目录 docs 主要是生成好的 AtomicXCore API 文档站点，也不能当成 SDK 的实现源码。

### 1.2 架构可以怎样准确概括

**主要形态是“UIKit 页面与组件 + Combine 响应式订阅 + AtomicXCore Store + 场景适配层”。**

更细地看：

- application：首页采用 Controller + Store/State，业务 Kit 经 AppAssembly 组装。
- chat：主要采用 Page → View/ViewImpl → ViewModel → Core Store。
- live：场景 View、局部 Store、Service、Router 分工并存。
- call：TUICallKit 门面、实现对象、CallManager、ViewState/GlobalState 和 Core CallStore 协作。
- room：Controller/View 组合 Core RoomStore、RoomParticipantStore，并用 Operator、Repository 等对象处理局部职责。
- api-example：Controller 直接调用和订阅 Core Store，便于展示 API。

**架构判断：**项目有清晰的产品组件边界，但内部模式并不完全统一。它不是严格的全项目 MVVM、Redux 或 Clean Architecture。大量业务主流程已经围绕 Store 构建，部分媒体、实验能力、上报和 IM 扩展仍直接访问底层 SDK。

### 1.3 总体依赖图

箭头表示主要依赖方向；为便于阅读，省略图片库、布局库等辅助依赖。

~~~mermaid
flowchart TB
    APP["RTCubeLab 综合体验 App"]
    LOGIN["Login/OpenSource"]
    ASSEMBLY["AppAssembly/OpenSource"]
    DEMO["ChatDemo / ChatDemoMini"]
    API["AtomicXCoreExample"]

    LIVE["TUILiveKit：直播与语音房"]
    CALL["TUICallKit_Swift：通话"]
    ROOM["TUIRoomKit：会议"]
    CHAT["TUIChatKit：聊天"]
    UI["AtomicX：公共 UI / 主题 / 工具"]
    CORE["AtomicXCore：核心 Store 与渲染组件"]
    TUI["TUICore：登录 / 动态服务 / 扩展"]
    ENGINE["RoomEngine / CallEngine / TRTC / IM"]

    APP --> LOGIN
    APP --> ASSEMBLY
    ASSEMBLY --> LOGIN
    ASSEMBLY --> LIVE
    ASSEMBLY --> CALL
    ASSEMBLY --> ROOM
    DEMO --> CHAT
    DEMO --> CALL
    ROOM --> CHAT
    LIVE --> UI
    CALL --> UI
    ROOM --> UI
    LIVE --> CORE
    CALL --> CORE
    ROOM --> CORE
    CHAT --> CORE
    UI --> CORE
    API --> CORE
    LOGIN --> TUI
    UI --> TUI
    CORE --> ENGINE
    LIVE -. "部分能力直接调用" .-> ENGINE
    CALL -. "部分能力直接调用" .-> ENGINE
    ROOM -. "部分能力直接调用" .-> ENGINE
    CHAT -. "AI 等适配" .-> ENGINE
~~~

Core 到底层引擎的关系可从依赖清单和公开调用边界确认；图不代表已经审阅其 SDK 内部实现。TUIChatKit 自身未声明依赖本地 AtomicX，也未声明 TUICallKit；聊天与通话的集成需要宿主补齐。

## 2. 工程与目录地图

### 2.1 可运行工程

| 工程 | Workspace / 主 Scheme | 最低系统配置 | 用途 |
|---|---|---|---|
| application | RTCube.xcworkspace / RTCubeLab | 主 App iOS 14；Replay target 声明 iOS 13 | 综合展示通话、直播、语音房、会议 |
| chat/demo | ChatDemo.xcworkspace / ChatDemo | App 和 Podfile iOS 15；Pod targets 被统一设为 14 | 完整聊天体验，含设置、通讯录、通话记录和客服集成 |
| chat/demo_mini | ChatDemoMini.xcworkspace / ChatDemoMini | iOS 14 | 最小页面接入示例 |
| api-example | AtomicXCoreExample.xcworkspace / AtomicXCoreExample | iOS 16 | 直接学习 Core Store 的四阶段直播示例 |

主工程只有 RTCubeLab 和 RTCubeLabReplayExtension 两个 native target。xcodebuild 能发现两个对应 scheme，其中仓库显式共享的是 RTCubeLab scheme。项目名称 RTCube 与 target 名称 RTCubeLab 不同，运行时应以 target/scheme 为准。

依据：[主工程 targets](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcodeproj/project.pbxproj:573)、[主 Podfile](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Podfile:1)、[ChatDemo Podfile](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/Podfile:1)、[Mini 配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo_mini/project.yml:1)、[API 示例配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/project.yml:1)。

### 2.2 目录职责

~~~text
TUIKit_iOS/
├── application/                 综合体验 App 与场景组装
│   ├── RTCube/                  AppDelegate、SceneDelegate、推送、日志、环境
│   ├── main/                    首页、模块列表与导航
│   ├── login/                   独立 Login Pod
│   ├── assembly/                独立 AppAssembly Pod
│   ├── mine/、language/         个人资料、偏好与语言页面
│   ├── RTCubeReplayExtension/   ReplayKit 广播扩展
│   ├── Debug/                   测试凭据与测试签名工具
│   ├── sdk/TXKTVScore/          本地 KTV 评分二进制封装
│   └── xcconfigs/              向 Pods 注入的 Lab/Dev 编译条件
├── atomic_x/                    AtomicX 公共 UI、Token、主题、图片上传
│   └── Sources/AlbumPicker/     独立 AlbumPicker Pod 源码，主 AtomicX 排除它
├── live/                        TUILiveKit：视频直播、语音房、互动组件
├── call/                        TUICallKit_Swift：通话与通话记录
├── room/                        TUIRoomKit：会议、Webinar、会议扩展能力
├── chat/
│   ├── uikit/                   TUIChatKit 聊天组件
│   ├── demo/                    完整聊天 Demo
│   └── demo_mini/               最小聊天 Demo
├── api-example/                 直接调用 AtomicXCore 的示例 App
├── TEBeautyKit/                 高级美颜包装 Pod
├── TCEffectPlayerKit/           礼物特效播放器包装 Pod
├── VideoAdvanceExtension/       视频高级能力 TUICore service
└── docs/                        生成的 AtomicXCore 文档站点及本文
~~~

main、mine、language 是主 App target 的源码组织目录；Login、AppAssembly 和各 Kit 则通过 Podspec 形成编译边界。不能把每个文件夹都视作独立 framework。

### 2.3 代码规模

统计口径：Git 已跟踪的 .swift/.h/.m/.mm 文件，排除 Pods；行数包含注释、空行和部分随仓库维护的格式解析代码，不等于有效业务代码量，也不等于某个 App 最终编译的代码量。

| 范围 | 源文件数 | 文本行数 |
|---|---:|---:|
| application | 138 | 18,003 |
| atomic_x | 60 | 11,284 |
| live | 289 | 63,217 |
| call | 64 | 11,337 |
| room | 101 | 24,632 |
| chat/uikit | 231 | 44,869 |
| chat/demo | 11 | 4,673 |
| chat/demo_mini | 3 | 435 |
| api-example | 21 | 8,655 |
| 三个可选扩展目录合计 | 10 | 875 |
| **以上合计** | **928** | **187,980** |

live 和 chat/uikit 是维护量最大的两个区域。阅读和后续重构应优先围绕具体场景进入，直接通读全部 View 的收益较低。

## 3. 依赖关系与构建边界

### 3.1 主工程如何组装本地源码

application/Podfile 对 Login、AppAssembly、AtomicX、TUICallKit_Swift、TUILiveKit、TUIRoomKit 和 TUIChatKit 使用本地路径。修改这些目录会影响主工程下一次正确解析依赖后的构建。

几个需要注意的依赖方向：

| 模块 | 主要显式依赖 | 架构含义 |
|---|---|---|
| AppAssembly | Login、三个场景 Kit、AtomicX/Core、RTCCommon、Alamofire | 综合 App 的组合适配层 |
| TUILiveKit | AtomicX、AtomicXCore、RoomEngine、TUICore、IMSDK | UI、局部状态与底层媒体桥接并存 |
| TUICallKit_Swift | AtomicX/Core、TUICore、RoomEngine、LiteAV、SDWebImage | 通话 UI 与引擎适配组件 |
| TUIRoomKit | AtomicX/Core、TUIChatKit、LiteAV | 会议内复用聊天能力，升级存在联动 |
| TUIChatKit | AtomicXCore、AlbumPicker、SnapKit、Masonry、Kingfisher | 独立聊天 UI 体系 |
| AtomicX | AtomicXCore、RoomEngine、LiteAV、TUICore、IMSDK | 虽是公共 UI 层，依赖图并不轻 |

依据：[AppAssembly.podspec](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/AppAssembly.podspec:18)、[AtomicX.podspec](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/AtomicX.podspec:19)、[TUIChatKit.podspec](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/TUIChatKit.podspec:16)、[TUIRoomKit.podspec](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/TUIRoomKit.podspec:28)。

工程采用 CocoaPods，多个本地 Pod 使用 static_framework；各 App 是否 use_frameworks、是否显式 static linkage，应分别看各自 Podfile。仓库未提供 Package.swift 作为统一 SPM 入口。

### 3.2 各工程没有统一 SDK 基线

以下是**提交中的锁文件记录值**，不是本次重新解析后验证过的版本：

| 依赖 | application | chat/demo_mini | api-example |
|---|---|---|---|
| AtomicXCore | 4.3.0 | 4.3.8 | 4.0.3 |
| AtomicX | 本地 1.0.0 | 远端 4.2.0 | 未声明 |
| RTCRoomEngine/Professional | 4.3.0 | 4.3.9 | 4.0.0 |
| TXLiteAVSDK_Professional | 13.4.21067 | 13.5.21355 | 13.1.20476 |
| TXIMSDK_Plus_iOS_XCFramework | 9.0.7662 | 9.1.7818 | 8.9.7511 |
| SnapKit | 5.0.1 | 5.7.1 | 5.7.1 |
| Kingfisher | 6.3.1 | 8.12.0 | 8.8.0 |

chat/demo 当前未提交 Podfile.lock，不能从本仓库确定其可复现的解析结果。

依据：[application 锁文件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Podfile.lock:31)、[Mini 锁文件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo_mini/Podfile.lock:6)、[API 示例锁文件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Podfile.lock:1)。

实际影响：

1. 同一业务 API 在一个 Demo 可用，不能据此认定另一个工程也兼容。
2. Mini 的本地源码仅包括 TUIChatKit、TUICallKit；它使用远端 AtomicX、AlbumPicker。修改根目录 atomic_x 后，在 Mini 中可能完全不生效。
3. application 的 Podfile 已包含 TUIChatKit，但其 lock 中没有 TUIChatKit 及 AlbumPicker/Masonry 等新增依赖，清单存在不同步。不能把旧 lock 视为当前源码已构建通过的证据。
4. 在未验证各 Kit 对 API 的需求前，不宜简单把 SDK 统一到某个版本；应先选定主工程并建立兼容矩阵。

### 3.3 当前编译分支

RTCubeLab 的 Debug/Release 都定义 RTCUBE_LOCAL_BUILD、RTCUBE_LAB、OPEN_SOURCE。Login 和 AppAssembly 当前均默认 OpenSource subspec；没有提供完整的 Full subspec。

因此：

- 当前实际登录页是 .debugAuth。
- 首页默认模块是 Call、Live、Room、VoiceRoom、ScenesApplication。
- APPASSEMBLY_FULL / LOGIN_FULL 内的其他入口不能视为当前可运行能力。
- 源码保留 overseas、手机号/邮箱、AI/同传/播放器等分支，不意味着相关模块已完整接入。

RTCubeLab 共享 scheme 在构建 pre-action 中遍历 Pods 的 xcconfig，注入 application/xcconfigs 下的配置；这些配置包含 RTCUBE_LOCAL_BUILD、RTCUBE_LAB、DEV_MODE。它会修改生成的 Pod 配置文件，使用其他构建入口时应核对宏是否传播一致。

依据：[主 App 编译条件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcodeproj/project.pbxproj:1015)、[Scheme pre-action](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcodeproj/xcshareddata/xcschemes/RTCubeLab.xcscheme:9)、[注入配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/xcconfigs/RTCubeLab.debug.xcconfig:4)。

### 3.4 可选扩展并未全部默认启用

| 目录 | 作用 | 启用方式与当前边界 |
|---|---|---|
| TEBeautyKit | 美颜面板、视频帧处理和 License 适配 | 独立 TEBeautyKitWrapper Pod，初始化后向 TUICore 注册 |
| TCEffectPlayerKit | MP4 礼物特效播放器 | 独立 Pod，通过 Objective-C +load 注册 service/extension |
| VideoAdvanceExtension | H265、HDR、B 帧、多档播放等实验能力 | 独立 Pod，向 TUICore 注册动态 service |
| application/sdk/TXKTVScore | KTV 评分 | 本地 XCFramework 与 Podspec，需按具体方案集成 |

主 Podfile 没有显式加入前三个扩展 Pod。目录存在、消费者调用存在，都不足以证明功能已启用。PAG 播放器有 canImport(libpag) 分支；MP4 播放器通过 TUICore 查找扩展，查不到时不会得到可用播放器。

依据：[美颜注册](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/TEBeautyKit/TUIBeautyKit.swift:229)、[特效服务注册](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/TCEffectPlayerKit/Classes/TUIExtension/TUIEffectPlayerService.m:20)、[视频高级服务](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/VideoAdvanceExtension/Sources/VideoAdvanceExtension.m:24)、[PAG 可用性分支](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/Gift/View/AnimationEngine/PAGAnimationEngine/PAGAnimationEngine.swift:11)、[MP4 扩展查找](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/Gift/View/Animation/TCEffectAnimationView.swift:44)。

## 4. 主 App 的启动与鉴权

### 4.1 启动流程

~~~mermaid
sequenceDiagram
    participant AD as AppDelegate
    participant SD as SceneDelegate
    participant HOME as EntranceViewController
    participant LE as LoginEntry
    participant AUTH as DebugAuthStore
    participant IM as TUILogin / IM
    participant BR as AtomicXCoreLogin
    participant CORE as Core LoginStore

    AD->>AD: 语言、主题、生命周期、License、推送等初始化
    SD->>HOME: 创建首页和 UINavigationController
    SD->>LE: initialize
    SD->>LE: launch(debugAuth)
    LE->>AUTH: 展示登录 UI
    AUTH->>AUTH: 生成测试 UserSig
    AUTH->>IM: login
    IM-->>AUTH: 登录成功并读取资料
    opt 无昵称
        AUTH->>AUTH: 注册昵称与头像
    end
    AUTH-->>LE: LoginResult
    LE->>LE: 更新 userModel 与持久化标记
    LE-->>SD: completion
    SD->>SD: 推送上报、启动动画、解除登录页
    LE-->>BR: userModel Publisher
    BR->>CORE: 独立异步 login
    CORE-->>BR: 结果，仅成功时报告指标
~~~

首页在登录页之前已经创建；登录成功后主要通过 dismiss 登录控制器进入首页，并不存在“登录完成才新建主页面”的统一切根流程。

依据：[AppDelegate](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/AppDelegate.swift:52)、[SceneDelegate](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:20)、[Debug 登录](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/DebugAuth/Store/OpensourceDebugAuthStore.swift:67)、[登录结果包装](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:192)、[Core 登录桥接](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/AtomicXCoreLogin.swift:19)。

### 4.2 登录分成三个概念

| 概念 | 当前实现 | 不能混同的状态 |
|---|---|---|
| App 用户状态 | LoginEntry.userModel、登录方式和自动登录标志 | 本地有标志不等于网络会话已就绪 |
| TUICore / IM 登录 | TUILogin.login，读取 V2TIM 用户资料 | IM 成功不等于 Core 后续登录完成 |
| AtomicXCore 登录 | AtomicXCoreLogin 监听 userModel，调用 LoginStore.login | 独立异步结果，失败当前未向壳层传播 |

hasLoggedIn 读取的是持久化的上次登录方式，不是 IM 当前连接状态查询。Lab 默认关闭自动登录，但开关可由用户偏好改变。

开源 Debug 登录路径通过本地测试签名直接登录 SDK，没有展示完整的业务账号后端鉴权。产出的 UserModel.token 为空；音乐目录、机器人等使用业务 token 的接口，需要另行核验后台约定。

依据：[登录标记](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:34)、[Lab 自动登录默认值](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:126)、[Debug UserModel](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/DebugAuth/Store/OpensourceDebugAuthStore.swift:163)。

### 4.3 退出与异常登录

LoginEntry 是统一退出门面；userModel 置空后，AtomicXCoreLogin 的订阅会调用 Core logout。登录监听对象负责处理踢下线、UserSig 过期与被动登出。

这里有两个需要优先处理的事实：

- 新用户注册完成后，emitResult 没有传回 UserSig，而该参数默认空串。
- 登录监听的实际注册依赖启动事件，当前注册时序可能错过该事件。

详细代码链路和建议见第 14 节。阅读退出逻辑时，还应确认各场景是否先结束当前会话、关闭采集和清理浮窗；“退出账号”与“销毁某个页面”不是同一个生命周期。

## 5. 首页装配、导航与模块通信

### 5.1 首页是怎样由模块拼成的

AppAssembly 提供模块列表，各模块遵循 ModuleProvider：

| 对象 | 职责 |
|---|---|
| ModuleProvider | 暴露 config、可见性、角标 Publisher，接受环境配置 |
| ModuleConfig | 模块标识、文案、卡片样式和页面工厂 targetProvider |
| ModuleEnvironment | License、当前用户读取、UserSig 生成闭包 |
| ModuleRegistry | 按 identifier 去重，强持有 provider |
| ResolvedModule | 首页可展示的配置与 provider 引用 |
| EntranceStore | 聚合可见模块和角标等首页状态 |
| EntranceViewController | 布局、订阅状态、权限检查、页面跳转 |

ModuleEnvironment 已具有依赖注入的雏形，但类型上仍引用 Login.UserModel；多数 SDK 也通过 .shared 访问，因此它没有实现完整的依赖反转。

依据：[ModuleProvider](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Interface/ModuleProvider.swift:9)、[ModuleConfig](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Interface/ModuleConfig.swift:9)、[ModuleEnvironment](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Interface/ModuleEnvironment.swift:9)、[ModuleRegistry](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/main/Shared/ModuleRegistry.swift:13)、[首页装配](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/main/EntranceViewController.swift:147)。

### 5.2 当前首页的业务入口

| 模块 | AppAssembly 工厂产物 | 后续进入的组件 |
|---|---|---|
| 通话 | CallViewController | TUICallKit_Swift |
| 视频直播 | LiveListViewController | TUILiveKit 列表、主播和观众页面 |
| 会议 | RoomHomeViewController | TUIRoomKit |
| 语音房 | VoiceRoomViewController | TUILiveKit VoiceRoom、Karaoke 配置 |
| 场景应用 | 场景展示入口 | 特殊外链处理 |

当前首页没有完整聊天模块入口；TUIChatKit 被依赖、会议内聊天能复用它，与“首页有独立聊天入口”是两回事。

实际首页点击流程是：

~~~text
点击模块卡片
  → ModulePermissionService 检查
  → 指标调用
  → 场景展示外链特殊处理
  → targetProvider 创建控制器
  → 按配置选择 push 或 fullScreen present
~~~

EntranceStore 也保留 selectModule，但当前首页点击路径在 Controller 中执行路由。后续扩展应先确定统一入口，避免两处路由逐渐分叉。

依据：[模块列表](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/AppAssembly.swift:66)、[首页点击处理](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/main/EntranceViewController.swift:415)、[Store 的另一条选择逻辑](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/main/Domestic/EntranceStore.swift:26)。

### 5.3 跨模块通信实际有五种方式

| 机制 | 典型使用 | 调试时的切入点 |
|---|---|---|
| 协议、闭包、工厂 | Provider、ModuleEnvironment、MineEntry、隐私/埋点回调 | 谁创建对象、谁持有闭包 |
| Combine | 登录同步、模块角标、Core State、通话状态 | 订阅时机、线程、去重和取消 |
| NotificationCenter | TUILoginSuccess、Chat 发起通话、消息页内部动作 | 通知名、参数键、观察者生命周期 |
| TUICore 动态服务/扩展 | 通话记录工厂、美颜、礼物播放器、高级视频能力 | service key 是否注册、返回值是否为空 |
| SDK observer / event Publisher | 房间事件、远端成员、IM 扩展数据 | 订阅或 observer 是否解绑 |

AppLifecycleRegistry 另提供生命周期转发：弱持有 handler，支持 URL、前后台和推送 token 回调；它不自动回放注册前已经发生的事件。

这意味着跨模块问题通常要同时看“对象关系”和“事件关系”。只沿页面调用栈查找，可能漏掉通知、动态服务或异步订阅。

依据：[生命周期注册器](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/Extension/AppLifecycleRegistry.swift:33)、[通话生命周期适配](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/Service/CallKitLifecycleHandler.swift:20)、[通话记录工厂](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/UI/CallingRecentCallsViewController.swift:25)、[Chat 通话通知](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/common/ChatCallEventPublisher.swift:5)。

## 6. 状态管理与数据流

### 6.1 通用数据闭环

~~~mermaid
flowchart LR
    USER["用户操作"] --> VIEW["UIKit View / Controller"]
    VIEW --> LOCAL["局部 Store / ViewModel / Manager"]
    LOCAL --> CORE["Core Store action"]
    CORE --> SDK["外部 SDK / 网络"]
    SDK --> CORE
    CORE --> STATE["State Publisher / Event Publisher"]
    STATE --> LOCAL
    LOCAL --> RENDER["主线程更新 UI"]
    RENDER --> USER
    VIEW -. "部分页面直接调用" .-> CORE
~~~

State 和 Event 需要分别理解：

- State：当前会话、成员、设备、消息等可持续读取的快照。
- Event：结束、被踢、收到新消息、操作失败等一次性通知。
- 本地 UI 状态：面板是否展开、当前路由、多选集合、输入草稿、媒体占位等。
- completion：某次命令的成功或失败，不应取代持续的状态订阅。

项目并非所有路径都严格经过同一中间层；某些 View 直接调用 Core Store，Service 也可能直接访问引擎。

### 6.2 状态归属与生命周期

| 作用域 | 典型对象 | 维护时重点 |
|---|---|---|
| App 全局 | LoginEntry、ThemeStore、LoginStore.shared、DeviceStore.shared、CallStore.shared | 换号重置、设备所有权、全局配置 |
| 某个房间/会话 | 消息 Store、房间成员 Store、礼物/弹幕/麦位 Store | ID 正确、离房清理、异步回调过期 |
| 页面 | Chat ViewModel、EntranceStore、直播局部 Store、路由状态 | 页面销毁后取消订阅、避免旧状态驱动新页面 |
| 单次操作 | 图片上传、媒体选择、邀请/申请、弹窗 completion | 取消、重试、幂等和并发结果 |

SDK 对 create(...) Store 的内部缓存与回收策略属于外部实现边界。可以确认调用方按房间/会话使用它们，不宜仅凭创建方法就断言 SDK 一定为每次调用分配全新实例。

### 6.3 当前最重要的架构约束

1. **登录是多个状态源。** App、IM、Core 需要明确的就绪条件。
2. **设备具有全局性。** 麦克风、摄像头、音频路由、屏幕采集不天然属于某一个 View。
3. **View 消失不一定代表会话结束。** 悬浮窗、PiP、页面切换和退出房间需要分别处理。
4. **状态可能有多个来源。** 聊天真实消息与本地媒体占位需要合并，不能把占位直接当作服务端消息。
5. **异步结果可能晚于页面。** 订阅释放、observer 解绑和回调中的场景 ID 校验是长期维护重点。

这些约束来自当前模块组合和状态使用方式；是否已经形成具体故障，需要按场景验证。

### 6.4 会话互斥与资源所有权

宿主当前的 canStartNewRoom 只检查 CallStore.selfInfo.status 是否为 .none，会议入口、直播创建和语音房创建会使用它。这是局部入口守卫；当前源码未见覆盖所有进入、切换、浮窗和退出路径的统一 Session Coordinator。

直播内部另有规则：观众连麦 CoGuest 与主播跨房 CoHost 在部分申请/连接阶段互斥，冲突时会拒绝另一类申请。这属于直播业务规则，不等于整个 App 的音视频资源仲裁。

媒体设备、音效、美颜是全局 Store，而清理动作分布在页面析构、通话结束等位置。后续允许多个音视频页面并存时，需要明确谁拥有当前会话、谁可以 reset，以及浮窗期间谁继续持有渲染视图。

依据：[宿主通话守卫](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/AppAssembly+CallGuard.swift:14)、[直播内部互斥](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorView/AnchorView.swift:460)。

## 7. 直播与语音房

### 7.1 模块边界

TUILiveKit 同时承载视频直播和语音房。大体目录分工：

| 范围 | 职责 |
|---|---|
| Sources/LiveStream | 对外入口、直播列表、主播准备、主播和观众控制器 |
| Sources/Features/LiveList | 列表 UI、分页与列表展示形式 |
| Sources/Features/AnchorPrepare | 开播前信息、模板、设备预览与设置 |
| Sources/Features/AnchorView | 主播 UI、局部 Store、Service、Router |
| Sources/Features/AudienceView | 观众观看、连麦/PK展示、观众管理、局部 Store/Router |
| Sources/VoiceRoom | 语音房入口、准备页、座位、管理面板和路由 |
| Sources/Component | 礼物、弹幕、点赞、美颜、音效、Karaoke、悬浮窗等组件 |
| Sources/Common | 国际化、资源、日志、标识、错误映射等 |

从入口看，应先读 VideoLiveKit、VoiceRoomKit 与几个 TUILiveRoom...ViewController，再进入具体 Features；单个 View 不承担完整的产品边界。

依据：[视频直播入口](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/LiveStream/VideoLiveKit.swift:1)、[语音房入口](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/VoiceRoom/VoiceRoomKit.swift:1)、[主播局部 Store](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorView/Store/AnchorStore.swift:1)、[观众局部 Store](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AudienceView/Store/AudienceStore.swift:1)。

### 7.2 内部职责分工

- Core Store：直播生命周期、设备、麦位、连麦、PK、观众、礼物、弹幕等核心状态和命令。
- 局部 Store：聚合当前页面需要的业务与 UI 状态，协调子能力。
- Service：房间能力、SDK 适配和部分引擎调用。
- RouterManager / RouteState / ControlCenter：管理面板、弹窗与页面路由状态。
- View / Overlay / VideoDelegate：视频视图上叠加昵称、状态、互动入口和场景 UI。

这里的 Store 命名不表示每个类都是完整独立的业务领域层；阅读时需要看它实际持有的是 Core 状态、本地 State，还是对引擎的包装。

### 7.3 视频直播的关键链路

~~~text
AppAssembly LiveModule
  → 直播列表 / 主播准备入口
  → 开启本地设备、配置直播信息和座位模板
  → Core LiveListStore 创建直播
  → LiveCoreView 绑定 liveID，渲染推流或播放
  → CoGuest / CoHost / Battle 等 Store 管理互动
  → 礼物、弹幕、点赞组件订阅房间范围状态和事件
  → 结束 / 离开直播，清理设备、订阅与场景 UI
~~~

主播与观众使用不同的页面编排。观众列表翻页切房、主播准备到正式开播、跨房连线和 PK，都会引入独立的房间生命周期，不能仅用“页面 present/dismiss”概括。

当前 TUILiveKit 的开播 action 是 LiveListStore.startLive；api-example 的锁定基线与示例代码使用 createLive。应按目标工程版本核对 API。准备页还会把原 LiveCoreView 传给主播页继续使用，保留已有的视频预览容器。

依据：[准备页传递 CoreView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/LiveStream/TUILiveRoomAnchorPrepareViewController.swift:85)、[正式开播](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorView/AnchorView.swift:341)、[观众进房](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AudienceView/AudienceLiveView.swift:848)。

### 7.4 语音房的特点

语音房使用 LiveListStore、LiveSeatStore 和相关互动 Store，属于 Live 体系；会议使用的 RoomStore 是另一套场景入口。语音房有独立的 VoiceRoomRootView、准备 Store、View Store、IM Store 和 Router，座位、锁麦、邀请、成员管理等是主要交互。

Karaoke 由独立组件处理；AppAssembly 的 VoiceRoomModule 订阅登录用户并注入音乐目录服务等配置。音乐目录同时依赖业务后台身份，与房间登录是不同链路。

依据：[语音房根视图](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/VoiceRoom/View/VoiceRoomRootView.swift:1)、[登录与 Karaoke 装配](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/VoiceRoom/VoiceRoomModule.swift:49)、[音乐目录服务](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/VoiceRoom/MusicCatalogServiceImpl.swift:73)。

### 7.5 仍然存在的底层穿透

AnchorService、AudienceService 及悬浮窗/PiP、音效、美颜和部分 IM 能力仍保留 RoomEngine、TRTC 或 IMSDK 调用。遇到音频路由、画面渲染、媒体处理或升级兼容问题，应沿实际调用向下追踪，不能止于 Core Store。

可选的视频高级功能通过 TUICore service 进入 VideoAdvanceExtension，再调用引擎 experimental API。这条链路依赖插件已安装并注册，也依赖 SDK 对实验接口的兼容性。

依据：[主播 Service](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorView/Store/AnchorService.swift:17)、[观众清晰度适配](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AudienceView/Store/AudienceService.swift:37)、[语音房 IM 关注关系](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/VoiceRoom/Manager/Module/VoiceRoomIMStore.swift:19)、[Karaoke 媒体对象](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/Karaoke/Manager/KaraokeManager.swift:20)。

### 7.6 应用内浮窗、系统 PiP 与退出

视频直播 FloatWindow.shared 会强持有原 Controller 和 LiveCoreView，把原渲染视图移动到当前窗口的浮层，恢复时重新展示原 Controller 并布局。关闭浮窗则根据当前身份调用 endLive 或 leaveLive。

系统 PiP 是另一条机制：PictureInPictureStore 通过 RoomEngine 的 enablePictureInPicture 实验接口配置。语音房的 FloatWindowProvider 类型还保留 TODO，不能据此认定它与视频浮窗具备相同的完整能力。

资源释放分散在多个位置：主播 Controller、观众 AudienceView 和语音房 Controller 析构时都重置全局 AudioEffectStore、DeviceStore、BaseBeautyStore。浮窗持有原对象，会使“退出全屏页面”和“对象析构”发生在不同时间，这也是会话所有权需要明确的原因。

依据：[浮窗持有与迁移](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/FloatWindow/FloatWindow.swift:50)、[语音房类型 TODO](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/FloatWindow/FloatWindow.swift:14)、[系统 PiP](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Component/PictureInPicture/PictureInPictureStore.swift:48)、[主播析构](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/LiveStream/TUILiveRoomAnchorViewController.swift:68)、[观众析构](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AudienceView/AudienceView.swift:65)、[语音房析构](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/VoiceRoom/TUIVoiceRoomViewController.swift:104)。

## 8. 音视频通话

### 8.1 模块结构

| 范围 | 职责 |
|---|---|
| TUICallKit / TUICallKitImpl | 对外门面与调用实现 |
| Manager | 通话管理、状态绑定、窗口和媒体等协调 |
| State | GlobalState、ViewState，保存全局配置和界面状态 |
| View / Feature | 1v1/群通话、邀请、浮窗、通话记录等 |
| Bridge | Objective-C/Swift 加载和 TUICore 互通 |
| Common | 本地化、工具、扩展和资源支持 |

对外 API 负责发起、加入、配置通话；Core CallStore 负责主要通话状态。CallManager 协调权限和操作命令，TUICallKitImpl 订阅状态与事件，配合 ViewState、WindowManager 决定通话界面的显示、切换和结束。

### 8.2 典型调用链

~~~text
宿主按钮 / Chat 通话通知
  → TUICallKit 门面
  → TUICallKitImpl
  → CallManager 权限与设备操作协调
  → Core CallStore 发起或加入
  → TUICallKitImpl 的状态与事件订阅
  → WindowManager / ViewState 控制窗口和界面状态
  → CallView / CallCoreView 订阅并渲染
  → 接听 / 拒绝 / 挂断继续调用 Store
~~~

项目不是只依赖 Core：TUICallKitImpl 保留 TUICallEngine 初始化及其他接口，源码还明确留有移除 RTCRoomEngine 的 TODO。PiP、实验接口和多端相关能力需要同时关注引擎层。

setupCallEngine 会调用 Core LoginStore.login，同时初始化 TUICallEngine。接听流程在权限弹窗完成后重新检查 callId，防止等待权限期间通话已经变化；这是一处明确的异步时序保护。

依据：[调用参数校验](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:67)、[状态订阅](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:237)、[事件与窗口更新](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:441)、[双初始化](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:328)、[权限后检查通话](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/Manager/CallManager.swift:29)。

**架构判断：**目前属于 Core 主流程与旧引擎适配共存的实现，后续升级需要验证两条路径的登录、状态和释放是否一致，不能仅升级 CallStore 的调用代码。

### 8.3 与宿主及聊天的集成

application 的 CallModule 提供体验页面，CallKitLifecycleHandler 在登录通知后配置悬浮窗、来电展示和其他能力；通话记录可通过 TUICore 对象工厂创建。

TUIChatKit 不直接依赖通话 Kit。ChatCallEventPublisher 发通知，通话 Kit 内置的 ChatCallEventSubscriber 再调用 TUICallKit.calls/join；TUICallKit.createInstance 会确保订阅，旧桥加载也会启动订阅。宿主需要集成并初始化通话 Kit，无需默认照搬一份 Demo 订阅者。

完整 ChatDemo 还存在自己的同名订阅实现，并在启动时订阅相同通知；接入和整理代码时应核对两处消费者，避免重复装配。是否触发重复呼叫及 SDK 如何处理，尚需运行验证。

依据：[Chat 通话通知协议](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/common/ChatCallEventPublisher.swift:27)、[Kit 确保订阅](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKit.swift:17)、[Kit 内置消费者](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/Bridge/Chat/ChatCallEventSubscriber.swift:25)、[Demo 自有订阅](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/ChatDemo/AppDelegate.swift:19)、[App 通话生命周期配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/Service/CallKitLifecycleHandler.swift:20)。

### 8.4 窗口与兼容桥

通话 WindowManager 使用独立 UIWindow，windowLevel 为 .alert + 1，通过窗口根控制器切换全屏、Banner 和浮窗；这与直播迁移原 CoreView 的方式不同。ViewState.router 表示 none、banner、fullView、floatView 等界面状态。

通话结束事件会停止转写、清理美颜和重置 DeviceStore；登出时还会挂断并销毁 TUICallEngine。主体实现是长期存活的单例，不能按普通页面对象推断其生命周期。

Bridge/Chat/Deprecated 中仍有有效的 Objective-C +load → swiftLoad 注册链，负责 TUICore service、扩展和对象工厂。Deprecated 目录名不表示代码已停止运行。VoIPDataSyncHandler 还负责与 TUICore 的接听、挂断、静音及路由信息互通。

依据：[通话窗口](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/Manager/WindowManager.swift:12)、[界面路由状态](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/State/ViewState.swift:10)、[结束清理](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:480)、[登出销毁](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/TUICallKitImpl.swift:342)、[兼容桥注册](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/Bridge/Chat/Deprecated/SwiftLoad.swift:14)、[VoIP 桥](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/call/TUICallKit_Swift/Bridge/VoIP/VoIPDataSyncHandler.swift:19)。

## 9. 会议与 Webinar

### 9.1 模块结构

| 范围 | 职责 |
|---|---|
| RoomHome/Create/Main 控制器 | 会议首页、创建和主会中页面 |
| View | 标准会议、Webinar、底栏、成员、邀请、日程与浮层 |
| Base/Operator | 设备和屏幕共享等操作协调 |
| Base/Config | 全局会议能力和界面配置 |
| Base/UI | 基础 View/Panel、路由上下文与弹层 |
| AITranscriptionView | 字幕、转录设置、纪要页面与 Repository |
| Resources | 多语言、图片、声音 |

主状态围绕 RoomStore 和 RoomParticipantStore；设备操作围绕 DeviceStore。TUIRoomKit 显式依赖 TUIChatKit，会议内聊天属于复用，而不是另写一套 IM。

依据：[会议主控制器](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/RoomMainViewController.swift:1)、[会议主视图](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:1)、[设备 Operator](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/Operator/DeviceOperator.swift:11)、[组件依赖](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/TUIRoomKit.podspec:28)。

### 9.2 操作与 UI 的关系

~~~text
创建 / 加入会议
  → RoomStore.createAndJoinRoom / joinRoom
  → RoomParticipantStore.getParticipantList
  → 按身份与全员设备策略应用 ConnectConfig
  → DeviceOperator / RoomParticipantStore 操作设备
  → 标准会议 / Webinar View 渲染
  → 主持人操作、举手、设备管理、邀请等调用相关 Store
  → State / Event 回流，刷新成员、底栏、弹层和布局
~~~

DeviceOperator 将设备回调包装为 async throws，供界面按顺序执行操作。项目中既有 Combine，也有 callback 和 Swift Concurrency；它们是不同的异步适配方式，不能据此认定整个模块已统一为 async/await。

标准会议视频单元使用 Core 的 RoomParticipantView。RouterContext 将 push/pop 抽象出来，默认依赖宿主 UINavigationController，接入时需要提供正确的导航上下文。

依据：[创建和加入](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:345)、[成员加载与入会配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:387)、[标准会议视频单元](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/Main/RoomView/RoomViewCell.swift:16)、[导航上下文](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/UI/RouterContext.swift:13)。

### 9.3 标准会议与 Webinar 的分叉

标准会议与 Webinar 有不同的成员布局和控制入口。WebinarRoomView 仍直接观察 RoomEngine、配置实验布局并调用 TRTC 渲染/远端视频控制；RoomDataReporter 也直接使用底层上报能力。

这说明部分媒体布局策略留在 UI 组件内部。修改 Webinar 的视频显示时，应同时检查 Core 的成员/设备状态与引擎的实际播放控制。

依据：[Webinar 实现](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/Main/RoomView/WebinarRoomView.swift:30)、[会议上报](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/Report/RoomDataReporter.swift:27)。

### 9.4 屏幕共享不是单一页面功能

主 App 内的共享入口、DeviceStore、ReplayKit 广播扩展、LiteAV ReplayKitExt、App Group 和签名配置共同构成屏幕共享链路。

当前 DeviceOperator 使用“主 App Bundle ID + .TUIKitReplay”定位扩展，工程中的实际扩展后缀为 .replay；这是一处确定的配置不一致。App Groups entitlement 的仓库配置也不足以确认最终签名能力，详见第 13、14 节。

### 9.5 转写、邀请与会议结束

房间级 AITranscriberRepository 包装 AITranscriberStore，整理实时转写片段、字幕及纪要展示数据，并通过 Publisher 交给 UI。结束会议会先停止转写再调用 RoomStore.endRoom，普通离开调用 leaveRoom。

RoomInvitationManager 是全局单例，负责邀请事件、邀请页、铃声和震动。RoomKit 经加载桥观察登录状态，登录后开始监听、登出后停止；它也能解析会议提醒和邀请推送。

调用 setAPNsCertificateID 时，邀请管理器会把 UNUserNotificationCenter.delegate 设置为自身。宿主接入其他推送能力时，应集中转发通知事件，明确最终代理归属，而不是让多个模块覆盖同一个 delegate。

依据：[转写 Repository](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/AITranscriptionView/Repository/AITranscriberRepository.swift:82)、[结束和离开](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:443)、[登录观察桥](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/Bridge/SwiftLoad.swift:15)、[邀请监听与推送代理](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/Invitation/RoomInvitationManager.swift:54)、[推送解析](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/Invitation/RoomInvitationManager.swift:272)。

## 10. 即时通信

### 10.1 组件分层

~~~text
宿主 App / Demo
  → ConversationsPage / ContactsPage / ChatPage
  → 组件包装 View
  → ViewImpl
  → ViewModel
  → AtomicXCore Store
  ← Store.state selector / Event Publisher
  ← ViewModel @Published
  ← ViewImpl 主线程渲染
~~~

几个核心 Store：ConversationListStore、MessageListStore、MessageInputStore、ContactStore、GroupStore、SearchStore、MessageActionStore。

这不是绝对的层层隔离：ChatPage 自己持有 ConversationListStore，群设置等页面也直接访问 Store。ViewModel 主要承担数据适配、部分 UI 状态和业务编排。

组件包装 View 不都能由外部独立创建：部分类型或初始化方法是 internal。宿主主要通过三个 Page、配置协议和公开的静态注册接口接入与扩展。

依据：[ChatPage 组合](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/ChatPage.swift:95)、[会话 ViewModel](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/conversationlist/viewmodel/ConversationListViewModel.swift:16)、[消息 ViewModel](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/viewmodel/MessageListViewModel.swift:24)。

### 10.2 功能目录

| 目录 | 职责 |
|---|---|
| conversationlist | 会话列表、未读、置顶、免打扰、创建会话 |
| messagelist | 消息 Cell、分页、回执、撤回/重发/转发、多选、回应、定位和媒体查看 |
| messageinput | 文本/表情/录音、更多菜单、@、引用、草稿、正在输入和媒体发送 |
| contactlist | 好友、申请、黑名单、群列表和联系人相关页面 |
| chatsetting | 单聊/群设置、成员、权限、资料与背景 |
| search | 全局/类型/会话内搜索、分页及定位 |
| ai | 翻译、转写、TTS 和自定义声音相关适配 |
| basecomponent / common | Chat 自有主题、Token、通用 UI、配置和通知 |
| 媒体与 emoji 组件 | 录音、播放、视频采集、视频播放和表情 |

### 10.3 文本消息发送与接收

~~~text
输入框
  → MessageInputViewModel 构造 SendMessagePayload
  → SendMessageOption 加入回执、@、引用、离线推送等参数
  → MessageInputStore.sendMessage
  → Core 更新消息状态
  → MessageListStore.state
  → MessageListViewModel 发布 messageList
  → MessageListViewImpl 应用列表
  → MessageCellRegistry 选择 Cell
~~~

发送失败通过回调回到 ChatPage 提示；新消息 Event 还会驱动未读清除、新消息入口等行为。列表更新与“收到新消息事件”承担不同职责。

依据：[消息发送](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messageinput/viewmodel/MessageInputViewModel.swift:56)、[消息订阅与合并](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/viewmodel/MessageListViewModel.swift:402)、[列表渲染](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/view/MessageListViewImpl.swift:461)、[Cell 注册器](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/cell/MessageCellRegistry.swift:73)。

### 10.4 媒体消息为什么更复杂

媒体选择通过 AlbumPickerMediaSendCoordinator 编排：

1. 建立当前会话的发送 session。
2. 选择、处理图片或视频。
3. 发布本地 sending 占位消息与进度。
4. 调用 Core 发送真实媒体消息。
5. MessageListViewModel 合并 Core 消息和本地占位，按本地媒体路径去重。

因此，“列表里出现了气泡”不代表消息已经发送到服务端。上传失败、页面退出、切会话、重发时，需要维护占位和真实消息的对应关系。

当前选择配置包含最多 9 项、视频 100MB/600 秒等限制；产品调整应从协调器与 Picker 配置入口着手。

依据：[媒体协调器](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messageinput/albumpickercoordinator/AlbumPickerMediaSendCoordinator.swift:20)、[占位与真实消息合并](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/viewmodel/MessageListViewModel.swift:412)。

### 10.5 已有的自定义能力

| 需求 | 现成扩展入口 |
|---|---|
| 页面顶部、返回、用户点击、更多按钮 | ChatPage 的配置和回调、topBannerView |
| 自定义消息卡片 | MessageListView.registerCustomMessageCell，按 businessID 注册 |
| 会话摘要适配 | 自定义消息 summary provider / matcher |
| 输入栏增加、隐藏、替换、排序菜单 | MessageInputActionCustomizer + CustomEditor |
| 消息过滤、回执、气泡和菜单策略 | MessageListConfigProtocol、MessageActionConfigProtocol 等 |
| 全局 UI 行为 | AppBuilderConfig JSON 配置及实例覆盖 |

完整 Demo 的 ChatFlowCoordinator 演示了 text_link 自定义消息和输入菜单注入。二次开发应优先利用这些入口，减少直接修改消息 ViewImpl 的范围。

依据：[自定义 Cell 注册](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/MessageListView.swift:254)、[输入栏自定义](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messageinput/MessageInputView.swift:173)、[自定义编辑器约束](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/common/uicustom/CustomEditor.swift:16)、[Demo 扩展示例](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/ChatDemo/Navigation/ChatFlowCoordinator.swift:84)。

### 10.6 Core 外的依赖与维护边界

AI 适配中有直接的 IMSDK 翻译和 experimental API 调用，群通话横幅也直接依赖 IMSDK；通话通过全局通知桥接。Chat 自有 ThemeState 和 AtomicX.ThemeStore 也不是同一套主题状态。

所以，替换 Core、抽离聊天或统一主题时，需要检查这些边缘路径。单独替换一个 ViewModel 的 Store，并不能覆盖全部 SDK 依赖。

依据：[AI 媒体处理](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/ai/AiMediaProcessManager.swift:126)、[Chat 主题状态](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/basecomponent/theme/ThemeState.swift:42)。

## 11. AtomicX 公共 UI 层

### 11.1 职责

AtomicX 提供按钮、头像、标签、弹窗、Popover、Toast 等组件，以及主题、设计 Token、图片选择/裁剪/上传和通用工具。

ThemeStore 持有当前 Theme，Token 覆盖颜色、间距、圆角、字体和阴影。AtomicButton 等组件订阅主题变化更新外观。

依据：[ThemeStore](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/Theme/ThemeStore.swift:19)、[AtomicButton 主题绑定](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/Widgets/BasicWidgets/AtomicButton/AtomicButton.swift:255)。

### 11.2 两套主题需要桥接

| 体系 | 状态源 | 当前使用范围 |
|---|---|---|
| AtomicX 主题 | ThemeStore.shared | AtomicX 组件及依赖它的场景 UI |
| Chat 主题 | ThemeState.shared、TUIChatKitTheme | TUIChatKit 和聊天 Demo |
| 会议局部主题策略 | RoomThemeManager 等 | 会议 UI 的局部样式处理 |
| App 壳策略 | AppDelegate 初始化主题/外观，当前强制浅色 | 综合体验 App |

Chat 的模式和主色持久化与 AtomicX 不共用同一个对象或键。当前未见完整的统一桥接。做品牌色、深浅色或换肤需求时，应从宿主集中同步多个入口，并验证窗口外观和动态 UIColor 的行为。

### 11.3 图片上传与相册边界

ImageUploader 包含系统照片选择、裁剪、本地文件管理和预签名 COS URL 的 PUT 上传；上传器最多重试 3 次，处理 5xx 与可恢复网络错误。

这个组件负责客户端文件处理和上传，不负责签发预签名 URL；签名和业务权限仍应由调用方系统提供。

AlbumPicker 虽然源码位于 atomic_x/Sources 下，但被主 AtomicX Podspec 排除，拥有自己的 Podspec。分析“为什么改了源码不生效”时，要先查目标 App 到底用本地 Picker 还是远端 Pod。

依据：[ImageUploader 入口](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/ImageUploader/ImageUploader.swift:35)、[上传实现](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/ImageUploader/Manager/ImageUploaderCosUploadManager.swift:8)、[AtomicX 排除规则](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/AtomicX.podspec:32)、[独立 Picker Pod](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/AlbumPicker/AlbumPicker.podspec:1)。

## 12. Demo 与 API 示例的区别

### 12.1 ChatDemo 与 Mini

| 比较项 | ChatDemo | ChatDemoMini |
|---|---|---|
| 启动组织 | SceneDelegate、RootViewController 按登录状态切换 | AppDelegate 直接创建 UIWindow |
| 产品界面 | 登录、会话、通话记录、通讯录、设置和多语言主题 | 简单按钮进入会话/单聊/群聊/联系人/视频通话 |
| 页面路由 | ChatFlowCoordinator 集中管理聊天与资料设置 | AppDelegate 直接 push |
| 客服 | 引入 TencentCloudAIDeskCustomer | 未声明该依赖 |
| 适合用途 | 理解完整接入与自定义策略 | 理解最少接入步骤 |
| 本地代码边界 | TUIChatKit、TUICallKit 为本地 Pod | 同左；AtomicX 仍来自远端 |

Mini 不是主工程的轻量 target，而是独立工程和独立依赖解析环境。

chat/demo/project.yml 仍写着 TUIKitDemo、旧源目录，与当前 ChatDemo.xcodeproj 不一致；不能未经核对就用它重新生成项目。Mini 和 api-example 的 project.yml 则与当前工程用途对应。

依据：[ChatDemo 根页面](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/ChatDemo/RootViewController.swift:59)、[Chat 路由协调](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/ChatDemo/Navigation/ChatFlowCoordinator.swift:13)、[Mini 入口](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo_mini/Sources/AppDelegate.swift:25)、[过期的生成配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo/project.yml:1)。

### 12.2 api-example 的四个阶段

| 场景 | 新增能力 | 主要 Store / View |
|---|---|---|
| BasicStreaming | 创建/加入、开关设备、推拉流 | LoginStore、LiveListStore、DeviceStore、LiveCoreView |
| Interactive | 礼物、点赞、弹幕、美颜、音效 | GiftStore、LikeStore、BarrageStore、BaseBeautyStore、AudioEffectStore |
| MultiConnect | 申请/邀请上麦、麦位与多人画面 | CoGuestStore、LiveSeatStore、LiveAudienceStore |
| LivePK | 跨房连线、PK、积分 | CoHostStore、BattleStore |

这四个页面是独立 Controller，场景能力逐级增加，不应理解为通过继承前一阶段 Controller 实现复用。Components 提供可复用面板、弹幕和礼物等 UI。

该工程直接依赖 Core，便于学习 API 的最小闭环；它不依赖本地 TUILiveKit。把这里的实现改好，也不会自动改变综合体验 App 中的直播页面。

依据：[API 页面路由](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Scenes/FeatureList/FeatureListViewController.swift:213)、[基础直播配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Scenes/BasicStreaming/BasicStreamingViewController.swift:134)、[开播](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Scenes/BasicStreaming/BasicStreamingViewController.swift:251)、[结束与退出](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Scenes/BasicStreaming/BasicStreamingViewController.swift:313)。

## 13. 横切能力与配置

### 13.1 网络与后台服务

当前 application 没有统一 HTTP client：

| 链路 | 实现方式 | 身份/数据来源 |
|---|---|---|
| IM/直播/通话/会议 | Core Store 或底层 SDK | SDKAppID、UserID、UserSig |
| 通话机器人 | 独立 Alamofire Service | 请求体中的业务身份参数 |
| 音乐目录 | MusicCatalogServiceImpl + Alamofire | userId、token、appId 等 |
| App Store 更新检查（保留实现） | AppDelegate 直接 URLSession | 当前 RTCUBE_LAB 条件下禁用 |
| 图片上传 | ImageUploader + URLSession PUT | 调用方提供的预签名 URL |

SDK 通信和业务 HTTP 没有一套统一的错误、重试、鉴权刷新策略。HTTP 服务可用性不能由 SDK 登录成功推导。App Store 更新检查受 !DEBUG && !RTCUBE_LAB 限制，当前主 target 不执行这项查询。

依据：[机器人服务](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/Service/HTTPRequstBotService.swift:13)、[音乐服务](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/VoiceRoom/MusicCatalogServiceImpl.swift:73)、[版本检查](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/AppDelegate.swift:295)。

### 13.2 本地数据与缓存

- UserDefaults：登录模式、自动登录、Debug UserID、语言、启动视频播放版本、部分功能偏好等。
- 文件：媒体临时文件、图片/音频资源、SDK 日志及各组件缓存。
- SDK 数据：消息、会话等主要经 SDK Store 操作，内部落盘策略不在当前仓库控制范围内。
- 在 application 可见源码中，未发现自建 CoreData、Realm、SQLite 或 Keychain 账号数据层；传递依赖里包含 sqlite3 不等于 App 自己实现了数据库层。

依据：[登录偏好](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:26)、[启动动画记录](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/LaunchAnimation/LaunchAnimationPlaybackRecord.swift:19)、[语言偏好](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/language/LanguageEntry.swift:39)。

### 13.3 推送

~~~text
App 启动
  → 请求通知权限并注册 APNS
  → PushLifecycleHandler 缓存 deviceToken
登录成功
  → reportDeviceToken
  → 向 IM 配置 APNS 信息
回到前台
  → 清除已投递和待投递通知
~~~

这条链路要求 APNS token 和登录状态相遇。目前 token 回调只缓存，登录成功时尝试上报，存在顺序敏感点。推送还依赖最终签名产物的 entitlement，仓库中的文件本身不构成成功接入证据。

依据：[APNS 注册](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/AppDelegate.swift:184)、[登录后上报](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:91)。

### 13.4 屏幕共享

~~~text
会议 DeviceOperator / 直播共享入口
  → RPSystemBroadcastPickerView 选择扩展
  → RTCubeLabReplayExtension 启动
  → SampleHandler 初始化 TXReplayKitExt
  → 系统 sampleBuffer 转交 SDK
  → SDK 将采集内容接入当前实时会话
~~~

需要共同核对的配置：

| 配置 | 当前源码事实 |
|---|---|
| preferredExtension | 消费端拼接主 Bundle ID + .TUIKitReplay |
| 工程实际 extension 标识 | 后缀为 .replay，与消费者不一致 |
| App Group 常量 | 主端与扩展中使用相同固定字符串 |
| App Groups entitlement | 仓库未提供完整可验证的绑定 |
| Deployment target | extension 声明 13，相关 Pod targets 被统一设为 14 |
| 扩展能力 | broadcast-services-upload，sample buffer 模式 |

ReplayKit2Define 中关闭的是旧 AppGroup/Darwin 通知分支；SampleHandler 仍向 TXReplayKitExt 传入 App Group。不能仅靠旧开关断言是否需要 App Group，应检查实际 SDK、签名产物与真机链路。

依据：[选择扩展](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/Operator/DeviceOperator.swift:81)、[扩展 Bundle ID](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcodeproj/project.pbxproj:1085)、[ReplayKit 初始化](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCubeReplayExtension/SampleHandler.m:176)、[sampleBuffer 转发](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCubeReplayExtension/SampleHandler.m:230)、[App Group 常量](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCubeReplayExtension/ReplayKit2Define.h:12)。

### 13.5 资源、主题与国际化

各 Kit 有独立资源 Bundle，例如 AtomicXBundle、TUILiveKitBundle、TUIRoomKitBundle、TUIChatKitBundle。资源修改需要确认 Podspec 是否打包、代码从哪个 Bundle 读取。

语言也存在多个入口：TUIGlobalization、App 的 LanguageEntry、Chat 资源与语言管理、api-example 的 LocalizedManager。API 示例切换语言会重建根导航页面。不要把一个 Demo 的语言策略直接当作全仓统一方案。

### 13.6 日志、指标与隐私配置

- AppLogger、LoginLogger、各 Kit 日志封装用于本地诊断。
- LogUploadManager 实际通过系统分享面板导出 .clog/.xlog 等文件，不是一个已完成的远程上传服务。
- 当前开源 AppAnalytics 是 no-op 壳；Core KeyMetrics 等调用仍存在，两者要分开理解。
- Info.plist 声明相机、麦克风、相册、audio/voip 后台模式，当前主 App 不支持多窗口。
- 配置常量集中在测试签名文件等位置，涵盖 SDKAppID、签名、推送、后台地址和 License；本文不复制凭据值。

依据：[日志导出](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/Log/LogUploadManager.swift:36)、[开源分析壳](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/Analytics/AppAnalytics.swift:10)、[权限与后台模式](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/Info/CN/Info.plist:60)。

## 14. 已发现的问题与维护风险

以下优先级是后续验证和维护顺序，不是对线上事故或安全事件的认定。除明确的配置/传参事实外，用户可见后果仍需编译或真机验证。

### 14.1 建议优先核对的具体问题

| 优先级 | 静态代码事实 | 可能影响与验证方式 |
|---|---|---|
| 高 | application Podfile 有 TUIChatKit，lock 未包含 | 依赖解析与源码不一致；重新安装前先检查差异和预期 SDK 基线 |
| 高 | 新用户 register 完成调用 emitResult 时未传 UserSig，默认空串 | Core 二次登录收到空凭据；验证首次注册后立即进入直播/会议 |
| 高 | AppDelegate 广播启动事件早于 Login handler 注册，registry 不补发 | TUILoginListenerHandler 的 TUILogin.add 可能不执行；验证踢下线和签名过期 |
| 高 | 首页解除登录遮挡未等待 Core 登录，Core 失败未回传 | App 显示已登录，但业务 Store 尚未就绪；验证慢网/登录失败/快速点击入口 |
| 高 | 屏幕共享期望 .TUIKitReplay，实际扩展为 .replay | 系统共享入口可能定位不到预期扩展；统一配置后真机验证 |
| 中 | APNS token 回调只缓存，登录时若 token 尚未到达则不上报 | 顺序改变可能遗漏 token 绑定；分别验证先登录/先拿 token |
| 中 | entitlement 文件未见 pbxproj 显式绑定，App Group 配置不完整 | 推送和共享能力取决于实际签名；检查最终产物而非只看源码 |
| 中 | Mini 用远端 AtomicX，主工程用本地 AtomicX | 开发者修改与运行版本错位；根据 lock 的 external sources 核对 |
| 中 | ChatDemo 的 project.yml 与实际工程不一致 | 重新生成可能覆盖成旧工程；更新生成源前先比对 pbxproj |
| 中 | 会议 endRoom/leaveRoom 返回失败后仍 pop 页面 | 可能出现 UI 离开但会话未成功退出；验证失败路径与补偿清理 |
| 中 | ChatDemo 与通话 Kit 都订阅同一套通话通知 | 核对消费者是否重复执行，避免复制接入代码时继续增加订阅 |

以下三个登录风险的证据链：

- 注册结果：[register](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/DebugAuth/Store/OpensourceDebugAuthStore.swift:103) → [emitResult 默认值](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/DebugAuth/Store/OpensourceDebugAuthStore.swift:163) → [Core 登录消费字段](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/AtomicXCoreLogin.swift:28)。
- 生命周期：[先广播](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/AppDelegate.swift:63) → [稍后初始化 Login](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:36) → [注册 handler](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:117) → [仅在启动回调 add](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/Components/Service/TUILoginListenerHandler.swift:23)；[registry.register](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/Extension/AppLifecycleRegistry.swift:43) 不回放事件。
- 就绪时序：[LoginEntry 回调](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:192) 与 [Core 异步订阅](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/AtomicXCoreLogin.swift:21) 分离；[Scene 成功路径](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:91) 不等待 Core 结果。

会议退出失败后导航的依据：[RoomMainView.endRoom/leaveRoom](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:443)。失败返回后的 SDK 会话状态和资源释放效果需要实测。

### 14.2 生产化边界

当前代码保留本地测试 UserSig 生成器，部分路径还打印签名内容或完整 UserSig；机器人请求日志也可能包含身份参数。若以此仓库继续做产品，应把正式 UserSig 签发放到业务服务端，并收敛日志中的凭据内容。

Info.plist 的 NSAllowsArbitraryLoads 为 true，这是已确认的传输策略配置；它不证明当前已经有明文请求。应按实际业务域名和资源协议评估所需范围。

依据：[API 示例签名日志](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/api-example/Scenes/Login/LoginViewController.swift:186)、[机器人参数日志](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/Service/HTTPRequstBotService.swift:13)、[ATS 配置](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/Info/CN/Info.plist:55)。

### 14.3 结构性维护风险

| 风险 | 当前证据与判断 | 建议 |
|---|---|---|
| 组件依赖偏重 | AtomicX 公共 UI 同时依赖多个实时 SDK | 有实际独立复用需求时再拆轻量基础 UI 与 SDK 适配 |
| SDK 封装不完全 | Core 与 RoomEngine/CallEngine/TRTC/IM 直连并存 | 建立直连清单，先封装高变更接口和实验 API |
| 全局状态较多 | shared Store、主题、登录、通知与设备 | 明确所有权和 reset 顺序，注入可替换接口 |
| 主题与语言多套来源 | Chat、AtomicX、Room、App 策略并存 | 在宿主建立统一配置适配，避免分别设置 |
| 字符串协议 | NotificationCenter、TUICore service/method/param | 统一声明协议、类型化参数并覆盖缺失注册路径 |
| 多入口版本漂移 | 各 Demo SDK、部署目标和资源来源不同 | 固定主工程与验证矩阵，分别维护锁文件 |
| 页面过大 | 消息列表、输入栏、语音房、会议主视图均较大 | 按滚动/媒体/交互/路由职责拆协调对象，避免纯按行数拆文件 |

作为维护复杂度的参考：MessageListViewImpl 1,669 行、MessageInputViewImpl 1,066 行、VoiceRoomRootView 1,546 行、RoomMainView 1,335 行。行数本身不是缺陷，但这些文件同时承担多种交互，改动回归范围较大。

### 14.4 测试和交付保障

Git 已跟踪源码中未发现 XCTest/UITest 测试目录或 test plan；四个工程当前列出的 native targets 也没有测试 target。RTCubeLab 的 TestAction 没有 testables。

.cnb.yml 当前主要执行 GitHub 同步，不能作为编译、测试或静态检查已经通过的证据。GenerateTestUserSig 和 TestTools 是调试辅助代码，不是自动化测试套件。

建议优先验证有真实行为风险的链路：

1. 老用户登录、新用户注册、Core 登录失败、踢下线、过期、退出后换号。
2. 创建/加入/结束房间，反复进入退出，弱网恢复与被动离房。
3. 通话、直播、会议之间切换时的设备释放、浮窗和 PiP。
4. 媒体占位到真实消息替换、失败重发、切会话、定位历史消息。
5. 最后一个好友删除、群成员变化、全局通知是否限定当前会话。
6. 真机推送的两种 token/登录到达顺序，以及屏幕共享完整链路。

依据：[空 TestAction](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube.xcodeproj/xcshareddata/xcschemes/RTCubeLab.xcscheme:44)、[当前 CI](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/.cnb.yml:2)、[好友空列表保护](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/contactlist/viewmodel/ContactListViewModel.swift:51)、[消息页全局通知](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/view/MessageListViewImpl.swift:482)。

## 15. 需求到代码的定位地图

| 要做的事情 | 优先读或改的入口 | 需要一起核对 |
|---|---|---|
| 改综合 App 启动/登录展示 | [SceneDelegate](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/RTCube/SceneDelegate.swift:74) | LoginEntry 与 Core 登录就绪 |
| 接正式账号系统 | [LoginEntry](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/login/Opensource/LoginEntry.swift:1) | UserModel 字段、UserSig 签发、过期/换号 |
| 给首页增加业务卡片 | [AppAssembly](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/AppAssembly.swift:66) | Provider、ModuleConfig、Podspec、权限与页面工厂 |
| 改首页排序/角标/隐藏 | [EntranceStore](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/main/Domestic/EntranceStore.swift:10) | Provider Publisher、Registry 生命周期 |
| 改直播开播准备 | [AnchorPrepareView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorPrepare/AnchorPrepareView.swift:1) | 设备、直播信息、模板与主播入口 |
| 改主播交互 | [AnchorView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AnchorView/AnchorView.swift:1) | AnchorStore、Service、Router |
| 改观看/切房/连麦 | [AudienceLiveView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/Features/AudienceView/AudienceLiveView.swift:1) | AudienceStore、媒体 Store、视频代理 |
| 改语音房座位或面板 | [VoiceRoomRootView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/live/Sources/VoiceRoom/View/VoiceRoomRootView.swift:1) | VoiceRoom View/Prepare/IM Store 与路由 |
| 改通话接入或行为 | [CallModule](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/assembly/Modules/Call/CallModule.swift:1) | TUICallKitImpl、CallManager、ViewState |
| 改会议主界面 | [RoomMainView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/View/RoomMainView.swift:1) | RoomStore、ParticipantStore、标准/Webinar 分支 |
| 改共享屏幕 | [DeviceOperator](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/room/Source/Base/Operator/DeviceOperator.swift:81) | Replay target、SampleHandler、Bundle ID、App Group |
| 接聊天页面 | [ChatPage](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/ChatPage.swift:109) | ChatFlowCoordinator、通话桥接、主题 |
| 加自定义消息 | [MessageListView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messagelist/MessageListView.swift:254) | businessID、发送 payload、摘要与 Cell |
| 改发送菜单或媒体限制 | [MessageInputView](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/uikit/components/messageinput/MessageInputView.swift:173) | MediaSendCoordinator、Picker、本地/远端 Pod 来源 |
| 改品牌色和深浅色 | [ThemeStore](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/atomic_x/Sources/Theme/ThemeStore.swift:19) | Chat ThemeState、RoomThemeManager 与窗口外观 |
| 排查“源码改了没效果” | [目标 Podfile](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/application/Podfile:1) | 实际 workspace、lock external sources、资源 Bundle |
| 排查 SDK API 差异 | [各工程锁文件](/Users/lihao/code/Xcode/kikitalk/TUIKit_iOS/chat/demo_mini/Podfile.lock:1) | Core/引擎/IM/LiteAV 整体版本，而非只看一个 SDK |

新增模块的推荐接入顺序：建立 Provider/Config → 明确页面工厂 → 通过 Environment 注入宿主能力 → 进入 AppAssembly 列表 → 核对 Podspec 源码和资源包含范围 → 验证权限与生命周期。

## 16. 架构演进建议

### 16.1 先稳定现有链路

第一阶段应集中在能直接影响行为的边界，而不是先更换 UI 框架：

- 选定主开发工程，补齐其依赖锁定与生成配置。
- 修复注册 UserSig 传递、登录监听注册和 Core 登录错误传播。
- 给“账号可用、IM 可用、Core 可用”建立明确状态和业务入口条件。
- 收敛推送与共享屏幕配置，完成真机验证。
- 对凭据日志做有针对性的清理。

完成标准：同一基线可复现构建；新老用户和失败路径一致；业务入口不会在 Core 未就绪时提前执行。

### 16.2 再收敛架构接口

第二阶段建议按实际改动频率推进：

| 方向 | 可落地做法 | 预期收益 |
|---|---|---|
| 会话协调 | 宿主集中管理账号、通话/房间状态、设备使用和退出顺序 | 减少跨场景互相干扰 |
| SDK 适配 | 将直连 experimental API、上报、媒体桥接集中到少量 Adapter | 降低升级时查漏成本 |
| 配置统一 | 用宿主配置对象桥接主题、语言、资源和 License | 减少跨模块显示差异 |
| 依赖可替换 | 给当前用户、凭据获取、关键 Store 操作提供协议或工厂 | 容易验证失败和时序场景 |
| 事件约束 | 明确通知的发送者、字段、会话 ID、接收者和释放时机 | 提升可追踪性与多页面隔离 |
| 大视图拆分 | 从媒体发送、滚动定位、浮层路由等真实职责拆出对象 | 控制回归范围 |

这里的 Adapter、会话协调和统一配置是建议新增的职责，当前仓库没有一套完整统一实现。应避免把未来建议误写为已经存在的架构。

### 16.3 以业务目标选择复用范围

- 如果重点是聊天：以 TUIChatKit + ChatDemo 的接入方式为起点，按需要保留通话；无需继承整个综合体验 App。
- 如果重点是直播/语音房：以 TUILiveKit 与 AppAssembly 对应适配为起点，先确定后台身份、License、礼物动画和 Karaoke 的实际范围。
- 如果重点是会议：优先考虑 TUIRoomKit，并接受其当前对聊天 UI 的依赖关系。
- 如果希望自建界面：api-example 能帮助理解 Core API，但要按目标工程的版本重新核验接口和生命周期。

这是基于当前代码边界的复用建议，具体裁剪仍应由产品功能范围决定。

## 17. 推荐阅读顺序与验证记录

### 17.1 第一轮阅读

| 顺序 | 文件/区域 | 应回答的问题 |
|---|---|---|
| 1 | application/Podfile、主工程、共享 scheme | 实际编译哪些模块和宏 |
| 2 | AppDelegate、SceneDelegate | 窗口、登录、生命周期怎样启动 |
| 3 | LoginEntry、DebugAuthStore、AtomicXCoreLogin | 身份和 SDK 就绪如何传递 |
| 4 | AppAssembly、ModuleProvider、EntranceViewController | 业务入口如何装配和路由 |
| 5 | 一个具体业务 Kit 的入口与主 View | 用户操作最终调用哪个 Store |
| 6 | 该场景的订阅、退出、浮窗和错误路径 | 状态如何回流，资源何时释放 |
| 7 | 主题、资源、通知、直接引擎调用 | 跨模块边界有哪些例外 |

### 17.2 本次已经完成的核查

- 扫描仓库目录、所有本地 Podspec、四个 App 的 Podfile/工程与已提交锁文件。
- 追踪综合 App 启动、注册/登录、首页装配、Core 登录同步和退出边界。
- 追踪聊天消息发送/接收、媒体占位、自定义消息、主题和通话桥接。
- 核对直播、语音房、通话、会议的场景分工与 Core/底层 SDK 并行路径。
- 核对 ReplayKit、推送、资源、业务网络、存储、日志、编译条件和 CI。
- 在本机 Xcode 26.5 下，对四个 .xcodeproj 执行 xcodebuild -list -json，均成功读取 target、scheme 和 Debug/Release 配置。
- 统计已跟踪源文件，并区分源码、生成文档、二进制依赖和本地 Pods。

### 17.3 尚未验证的边界

未执行 pod install、pod update、完整 build/test、签名归档、运行 App、后台接口调用或真机实时音视频测试。当前本机仅 Mini 存在 Pods 目录，其他三个工程的 Pods 未安装。

因此，本文件是**基于源码与工程配置的架构拆解**，不是“全部功能可运行”的验收报告。第 14 节的问题应按证据链逐项复核；外部 SDK 的线程契约、Store 缓存、网络协议和内部持久化仍以实际版本接口与运行结果为准。

本文代码链接使用当前工作区绝对路径，并锚定本次基线的行号；移动仓库或修改源码后，需要重新定位。
