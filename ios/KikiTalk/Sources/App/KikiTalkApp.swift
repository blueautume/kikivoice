import SwiftUI

@main
struct KikiTalkApp: App {
    @UIApplicationDelegateAdaptor(KikiPushAppDelegate.self) private var pushDelegate
    var body: some Scene {
        WindowGroup { KikiRootView() }
    }
}
