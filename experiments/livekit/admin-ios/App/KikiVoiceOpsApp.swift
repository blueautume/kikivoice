import SwiftUI

@main
struct KikiVoiceOpsApp: App {
    @StateObject private var store = OpsStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            OpsRootView(store: store)
                .tint(.indigo)
                .onChange(of: scenePhase, initial: true) { _, phase in store.setActive(phase == .active, cancelAuthorization: phase == .background) }
                .overlay {
                    if scenePhase != .active {
                        Rectangle().fill(.regularMaterial).ignoresSafeArea()
                            .overlay { Label("Kiki 运维", systemImage: "waveform.path.ecg").font(.headline) }
                    }
                }
        }
    }
}
