# KikiTalk iOS

[简体中文](README.cn.md) · [iOS projects](../README.md) · [Repository](../../README.md) · [Architecture](../../docs/ARCHITECTURE.zh-CN.md) · [Project handover](../../docs/PROJECT_HANDOVER.zh-CN.md)

Open **KikiTalk.xcworkspace** in Xcode and select **KikiTalk**. The app requires iOS 17 or later and supports iPhone/iPad; the test target is KikiTalkTests.

## Dependencies and signing

Xcode resolves LiveKit through Swift Package Manager. The workspace's `xcshareddata/swiftpm/Package.resolved` records exact package versions. Use the existing simulator signing configuration for system Keychain, or an authorized team and device for a physical build.

Review Apple sign-in, push notification, and background-audio capabilities when changing signing. Info.plist and entitlements live in `Configuration/`; PrivacyInfo.xcprivacy is a bundled resource.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Sources/App/` | KikiTalkApp, KikiRootView, KikiAppStore, startup preparation |
| `Sources/Core/Networking/` | Account/voice HTTPS clients and redirect policy |
| `Sources/Core/Storage/` | Identity storage protocol and Keychain implementation |
| `Sources/Core/DesignSystem/` | Shared palette and avatar rendering |
| `Sources/Core/Notifications/`, `Diagnostics/` | APNs routing/registration and incident reporting |
| `Sources/Features/Authentication/`, `Privacy/` | Apple authorization/login, legal consent and withdrawal |
| `Sources/Features/VoiceRooms/` | Models, discovery, RTC services, room views, presentation, chat |
| `Sources/Features/Gifts/` | Experience balance, gift queue/effects, decorations |
| `Sources/Features/Social/`, `Moments/`, `Messaging/` | People/relationships, feed/comments, inbox/private conversations |
| `Sources/Features/Profile/` | Profile editing, settings, room collections, safety entry points |
| `Tests/` | App/Core/Features tests and explicitly enabled Integration checks |
| `Resources/` | Assets, gifts, legal-document copy, launch storyboard, privacy manifest |
| `Configuration/` | Info.plist and KikiTalk.entitlements |

The app store coordinates shared business/session state; the root view handles gates and navigation. Existing complete top-level types such as palette, avatar, room models, discovery views, unread gate, and room helper views have been extracted into their own files. Larger Social/Profile/Consent test files still retain multiple responsibilities; this organization does not introduce a separate package per folder.

## Resource tools

Repository tools now target this project's `Resources/` directory. From the repository root, `python3 tools/build_legal_documents.py --check` checks legal outputs without changing them. Brand and gift generation remain explicit asset-authoring commands; moving a source directory does not require regenerating assets or changing legal text.

## Validation scope

Most tests use local fixtures. Public-service and device/media tests require documented environment flags and credentials; review each test before enabling it. A skipped integration test does not establish production behavior. The old application/RTCube source path was migrated here on 2026-10-22; backend deployments and published legal documents are separate from this directory change.

The independent operations app is at [../KikiVoiceOps](../KikiVoiceOps/README.zh-CN.md).
