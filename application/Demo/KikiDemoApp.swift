import SwiftUI

@main
struct KikiDemoApp: App {
    @UIApplicationDelegateAdaptor(KikiPushAppDelegate.self) private var pushDelegate
    var body: some Scene {
        WindowGroup { KikiDemoRootView() }
    }
}
