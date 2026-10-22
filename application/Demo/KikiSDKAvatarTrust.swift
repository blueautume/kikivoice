import Foundation

/// Native URL loading uses the system CA trust store, with no certificate exceptions.
enum KikiSDKAvatarTrust {
    static func install() { }
    static func clearPrivateImages() { URLCache.shared.removeAllCachedResponses() }
}
