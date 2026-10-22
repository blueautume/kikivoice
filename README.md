# KikiTalk

[简体中文](README.cn.md) · [iOS projects](ios/README.md) · [Architecture](docs/ARCHITECTURE.zh-CN.md) · [Project handover](docs/PROJECT_HANDOVER.zh-CN.md)

KikiTalk is an iOS voice community with Apple sign-in, eight-seat voice rooms, moments, private messages, notifications, and a personal profile. Audio uses self-hosted LiveKit. Account/social and voice APIs are separate services.

## Run the iOS apps

| App | Workspace | Scheme |
| --- | --- | --- |
| KikiTalk user app | `ios/KikiTalk/KikiTalk.xcworkspace` | KikiTalk |
| KikiVoiceOps operations app | `ios/KikiVoiceOps/KikiVoiceOps.xcworkspace` | KikiVoiceOps |

Open the desired workspace in Xcode. Both apps require iOS 17 or later and support iPhone/iPad. KikiTalk resolves its pinned LiveKit packages through Swift Package Manager; KikiVoiceOps uses system frameworks. Use the existing simulator signing settings, or an authorized development team and device for a physical build.

See the [KikiTalk guide](ios/KikiTalk/README.md) and [KikiVoiceOps guide](ios/KikiVoiceOps/README.zh-CN.md). The former application/RTCube and experimental admin paths have been consolidated under `ios/`; CocoaPods and Tencent SDK configuration are no longer part of the setup.

## Repository map

| Path | Purpose |
| --- | --- |
| `ios/KikiTalk/` | User app: Sources/App, Core and Features; Tests, Resources, Configuration |
| `ios/KikiVoiceOps/` | Independent operations app with the same main layout and local Scripts |
| `backend/` | Account, social, APNs, and central operations identity service |
| `experiments/livekit/backend/` | Current voice business API and LiveKit signal gateway |
| `experiments/livekit/infra/` | Media/API deployment configuration, maintenance, and probes |
| `experiments/livekit/shared/` | Cross-service contracts and voice legal-document copy |
| `experiments/livekit/validation/` | Local generated validation evidence; excluded from Git |
| `website/dist/`, `legal/`, `tools/` | Website, legal source documents, and generation tools |
| `docs/` | Current architecture, handover, and dated delivery records |

The `experiments/livekit` name is historical; its backend, infrastructure, and contracts remain in use. The independent experimental iOS client, Tencent components/sample apps, old targets, CocoaPods setup, and vendor snapshots were removed during the 2026-10-22 iOS cleanup.

## Service boundaries

- `https://kiki.group`: Apple authentication, profiles, social content, APNs, legal consent, and operations identity.
- `https://furby.top` / `wss://furby.top`: voice authorization, rooms, seats, room chat, gifts/decorations, and LiveKit signaling/media.

Account, voice, room, and operations credentials serve different purposes. Client code receives server-issued credentials; signing secrets stay outside the app.

See the [account backend guide](backend/README.zh-CN.md) and [voice service guide](experiments/livekit/backend/README.zh-CN.md) for service setup. Dated delivery records describe their own release batches and do not establish the current deployment or test status. Links to `output/` or `experiments/livekit/validation/` refer to local evidence excluded from Git; these files are not included in a clone.

The repository originated from Tencent TUIKit_iOS. Retained source and assets keep their applicable license notices; the current iOS application uses LiveKit rather than the former Tencent implementation.
