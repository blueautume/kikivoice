# KikiTalk iOS

[简体中文](README.cn.md) · [Repository overview](../README.md) · [Architecture](../docs/ARCHITECTURE.zh-CN.md) · [Project handover](../docs/PROJECT_HANDOVER.zh-CN.md)

Open `RTCube.xcworkspace` in Xcode and select **KikiTalk**. The project requires iOS 17 or later, supports iPhone/iPad, and keeps its historical RTCube filename. Its application and test targets are KikiTalk and KikiTalkTests.

## Dependencies and signing

Xcode resolves LiveKit through Swift Package Manager. The workspace's `xcshareddata/swiftpm/Package.resolved` records exact package versions. CocoaPods and Tencent SDK configuration have been removed; do not run the former pod-install or UserSig setup instructions.

Use the existing simulator signing configuration so system Keychain remains available. For a physical device, select an authorized development team and review the Apple sign-in, push notification, and background-audio capabilities.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Demo/KikiDemoApp.swift`, `KikiDemoRootView.swift` | App entry, consent/startup/login gates, four tabs |
| `Demo/KikiDemoStore.swift` | Shared account and product state, service orchestration, session teardown |
| `Demo/KikiAccountAPIClient.swift` | Account/social HTTPS requests to kiki.group |
| `Demo/KikiAPIClient.swift` | Voice business HTTPS requests to furby.top and shared models |
| `Demo/KikiRTCService.swift`, `KikiRoomRuntime.swift` | LiveKit connection, room/audio lifecycle, chat synchronization |
| `Demo/KikiLiveKitRoomView.swift`, `KikiRoom*.swift` | Voice-room UI and interaction components |
| `Demo/KikiSocial*.swift`, `KikiMomentsViews.swift`, `KikiDirectMessages.swift` | People/relationships, feed/comments, inbox/private conversations |
| `Demo/KikiProfileView.swift`, `KikiSettingsLayout.swift` | Profile, account settings, room collections, safety entry points |
| `Demo/KikiGifts.swift`, `KikiGiftViews.swift` | Experience balance, gifts, decorations, presentation |
| `Demo/KikiLegal*.swift`, `KikiPush.swift`, `KikiStartupPermissions.swift` | Consent, notifications, startup permissions |
| `Demo/Resources/`, `Demo/Assets.xcassets/` | App resources, gifts, legal-document copy, brand assets |
| `DemoTests/` | Current app tests; select KikiTalk's Test action |

The `Demo` names identify the current product source, not a second sample application. The old Tencent app/extension, components, reference targets, Pods, and separate LiveKit lab client have been removed. KikiVoiceOps remains an independent project at `../experiments/livekit/admin-ios/`.

## Validation scope

Most tests use local fixtures. Public-service and device/media integration tests require their explicitly documented environment flags and credentials; review each test before enabling it. A skipped integration test does not establish production behavior. This cleanup changes neither backend deployments nor published legal documents.
