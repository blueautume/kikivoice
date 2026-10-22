# KikiTalk

[简体中文](README.cn.md) · [iOS development](application/README.md) · [Architecture](docs/ARCHITECTURE.zh-CN.md) · [Project handover](docs/PROJECT_HANDOVER.zh-CN.md)

KikiTalk is an iOS voice community with Apple sign-in, eight-seat voice rooms, moments, private messages, notifications, and a personal profile. Audio uses a self-hosted LiveKit service. Account/social and voice APIs are separate services.

## Run the iOS app

1. Open `application/RTCube.xcworkspace` in Xcode and select the **KikiTalk** scheme.
2. Let Xcode resolve the pinned Swift packages. The app requires iOS 17 or later and supports iPhone and iPad.
3. Use the project's signing configuration for the simulator; choose an authorized development team and device for a physical build.

The project/workspace name `RTCube` is retained for the current app. The only application target in this project is KikiTalk, with KikiTalkTests for tests. Dependencies use Swift Package Manager; CocoaPods and Tencent SDK configuration are no longer part of the iOS setup.

## Repository map

| Path | Purpose |
| --- | --- |
| `application/Demo/` | Current KikiTalk SwiftUI/UIKit application |
| `application/DemoTests/` | Current client tests and explicitly enabled integration checks |
| `backend/` | Account, social, APNs, and central operations identity service |
| `experiments/livekit/backend/` | Current voice business API and LiveKit signal gateway |
| `experiments/livekit/admin-ios/` | Independent KikiVoiceOps app for operations and moderation |
| `experiments/livekit/infra/` | Media/API deployment configuration, maintenance, and probes |
| `experiments/livekit/shared/` | Cross-service contracts and voice legal-document copy |
| `experiments/livekit/validation/` | Local generated validation evidence; excluded from Git |
| `website/dist/`, `legal/`, `tools/` | Website, legal source documents, and generation tools |
| `docs/` | Current architecture, handover, and dated delivery records |

The `experiments/livekit` name is historical; its backend, admin app, infrastructure, and contracts are used by the current product. The separate experimental iOS app, Tencent components/sample apps, old targets, CocoaPods setup, and vendor snapshots were removed during the 2026-10-22 iOS cleanup.

## Service boundaries

- `https://kiki.group`: Apple authentication, profiles, social content, APNs, legal consent, and operations identity.
- `https://furby.top` / `wss://furby.top`: voice authorization, rooms, seats, room chat, gifts/decorations, and LiveKit signaling/media.

Account, voice, room, and operations credentials serve different purposes. Client code receives server-issued credentials; signing secrets stay outside the app.

See the [account backend guide](backend/README.zh-CN.md), [voice service guide](experiments/livekit/backend/README.zh-CN.md), and [operations app guide](experiments/livekit/admin-ios/README.zh-CN.md) for their respective setup. Dated delivery records describe their own release batches and do not establish the current deployment or test status. Links to `output/` or `experiments/livekit/validation/` refer to local evidence excluded from Git; these files are not included in a clone.

The repository originated from Tencent TUIKit_iOS. Retained source and assets keep their applicable license notices; the current iOS application uses LiveKit rather than the former Tencent implementation.
