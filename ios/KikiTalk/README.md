# Kiki iOS

[简体中文](README.cn.md) · [iOS projects](../README.md) · [Repository](../../README.md) · [Architecture](../../docs/ARCHITECTURE.zh-CN.md) · [Project handover](../../docs/PROJECT_HANDOVER.zh-CN.md)

The visible app name is **Kiki**, with an uppercase initial; the project, paths, and scheme remain KikiTalk. Open **KikiTalk.xcworkspace** in Xcode and select **KikiTalk**. The app requires iOS 17 or later and supports iPhone/iPad; the test target is KikiTalkTests.

## Startup and appearance

Normal startup displays only the brand icon and Kiki while silently checking consent. The consent page appears only when acceptance of the current documents is required; users with current consent continue to session restoration. Room backgrounds use native SwiftUI gradients with separate light and dark palettes; they do not copy system wallpapers.

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
| `Sources/Features/VoiceRooms/` | Room models, five backgrounds, creation/editing, RTC, room views, chat |
| `Sources/Features/Social/`, `Messaging/` | People, mutuals/following/followers, inbox/private text conversations |
| `Sources/Features/Profile/` | Profile editing, settings, room collections, safety entry points |
| `Tests/` | App/Core/Features tests and explicitly enabled Integration checks |
| `Resources/` | Assets, legal-document copy, launch storyboard, privacy manifest |
| `Configuration/` | Info.plist and KikiTalk.entitlements |

The app store coordinates shared business/session state; the root view handles gates and navigation. Existing complete top-level types such as palette, avatar, room models, discovery views, unread gate, and room helper views have been extracted into their own files. Larger Social/Profile/Consent test files still retain multiple responsibilities; this organization does not introduce a separate package per folder.

## Resource tools

Brand tools target this project's `Resources/` directory. From the repository root, `python3 tools/build_legal_documents.py --check` checks legal outputs without changing them. Rooms offer five presets that adapt to the system appearance: 简约, 晨光, 晴空, 暮色, and 薄荷. Select a preset when creating a room or edit it as the owner; see [room backgrounds](../../docs/ROOM_BACKGROUNDS.zh-CN.md). The separate decoration system has been removed.

## Validation scope

Most tests use local fixtures. Public-service and device/media tests require documented environment flags and credentials; review each test before enabling it. A skipped integration test does not establish production behavior. The old application/RTCube source path was migrated here on 2026-10-22; backend deployments and published legal documents are separate from this directory change.

The independent operations app is at [../KikiVoiceOps](../KikiVoiceOps/README.zh-CN.md).
