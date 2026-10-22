#if KIKI_DEMO_STANDALONE
import SwiftUI

@main
struct KikiDemoApp: App {
    @UIApplicationDelegateAdaptor(KikiPushAppDelegate.self) private var pushDelegate
    var body: some Scene {
        WindowGroup { KikiDemoRootView() }
    }
}
#endif
