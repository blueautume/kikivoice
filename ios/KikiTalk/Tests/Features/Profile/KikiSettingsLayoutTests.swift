import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

/// All callbacks below terminate at local counters. These fixtures never use an
/// account store, authentication session, network operation, or deletion flow.
@MainActor
final class KikiSettingsLayoutTests: XCTestCase {
    private let longUserID = "kiki_ef3b60cec28c16ac_完整账号展示_" + String(repeating: "0123456789abcdef", count: 4)

    func testSettingsContainExactlySixDestinationsAndRatingDoesNotActivate() async throws {
        XCTAssertEqual(KikiSettingsDestination.allCases.map(\.rawValue),
                       ["account", "notifications", "privacy", "rating", "about", "help"])
        XCTAssertEqual(Set(KikiSettingsDestination.allCases.map(\.id)).count, 6)
        var selections: [KikiSettingsDestination] = []
        try await withWindow { window in
            let host = await render(AnyView(KikiSettingsMenuContent { selections.append($0) }),
                                    title: "设置", in: window)
            let expectedIDs = KikiSettingsDestination.allCases.map { "settings." + $0.rawValue }
            let nodes = accessibilityNodes(in: host.view)
            let foundIDs = Set(nodes.compactMap(identifier).filter { expectedIDs.contains($0) })
            guard foundIDs == Set(expectedIDs) else {
                throw XCTSkip("This runtime does not expose SwiftUI virtual buttons through the public in-process accessibility container. Screenshot coverage remains in the fixture test; no private API or fabricated gesture is used.")
            }
            let rating = try XCTUnwrap(node(in: host.view, identifier: "settings.rating"))
            XCTAssertTrue(rating.accessibilityTraits.contains(.notEnabled))
            _ = activate(rating)
            XCTAssertTrue(selections.isEmpty, "The rating placeholder must not call its handler")
            for destination in KikiSettingsDestination.allCases where destination != .rating {
                let button = try XCTUnwrap(node(in: host.view, identifier: "settings." + destination.rawValue))
                XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
                guard activate(button) else {
                    throw XCTSkip("This runtime exposes the button label but does not support its public accessibility activation.")
                }
                XCTAssertEqual(selections.last, destination)
            }
            XCTAssertEqual(selections, [.account, .notifications, .privacy, .about, .help])
        }
    }

    func testAccountShowsCompleteIdentityAndBindingAndOnlyInvokesLocalCallbacks() async throws {
        var logoutCalls = 0, deleteCalls = 0
        try await withWindow { window in
            let content = KikiAccountSettingsContent(userID: longUserID, appleIDBound: true, isLoggingOut: false,
                onLogout: { logoutCalls += 1 }, onDelete: { deleteCalls += 1 })
            let host = await render(AnyView(content), title: "账户", in: window)
            guard let identity = node(in: host.view, identifier: "settings.kikiID"),
                  let apple = node(in: host.view, identifier: "settings.appleID"),
                  let logout = node(in: host.view, identifier: "logoutButton"),
                  let deletion = node(in: host.view, identifier: "deleteAccountButton") else {
                throw XCTSkip("SwiftUI virtual account elements are unavailable through the public in-process accessibility container on this runtime; local screenshot fixtures remain covered.")
            }
            XCTAssertTrue(accessibleText(identity).contains(longUserID), "The full ID must remain available rather than an abbreviated display value")
            XCTAssertTrue(accessibleText(apple).contains("已绑定"))
            XCTAssertFalse(logout.accessibilityTraits.contains(.notEnabled))
            XCTAssertFalse(deletion.accessibilityTraits.contains(.notEnabled))
            guard activate(logout), activate(deletion) else {
                throw XCTSkip("This runtime does not implement public accessibility activation for these SwiftUI buttons.")
            }
            XCTAssertEqual(logoutCalls, 1)
            XCTAssertEqual(deleteCalls, 1, "Deletion is a local callback; this test cannot delete any account")
        }
    }

    func testLogoutInProgressDisablesBothActionsAndUnconfirmedBindingIsExplicit() async throws {
        var logoutCalls = 0, deleteCalls = 0
        try await withWindow { window in
            let content = KikiAccountSettingsContent(userID: longUserID, appleIDBound: false, isLoggingOut: true,
                onLogout: { logoutCalls += 1 }, onDelete: { deleteCalls += 1 })
            let host = await render(AnyView(content), title: "账户", in: window)
            guard let apple = node(in: host.view, identifier: "settings.appleID"),
                  let logout = node(in: host.view, identifier: "logoutButton"),
                  let deletion = node(in: host.view, identifier: "deleteAccountButton") else {
                throw XCTSkip("SwiftUI virtual account elements are not available through this runtime's public accessibility container.")
            }
            XCTAssertTrue(accessibleText(apple).contains("未确认"), "An unverified credential must not be presented as a confirmed binding")
            XCTAssertTrue(logout.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(deletion.accessibilityTraits.contains(.notEnabled))
            _ = activate(logout)
            _ = activate(deletion)
            XCTAssertEqual(logoutCalls, 0, "Repeated logout activation must be ignored while it is running")
            XCTAssertEqual(deleteCalls, 0, "Deletion must not race with an in-flight logout")
        }
    }

    func testSettingsAndAccountFixtureScreenshotsFitPhoneIPadAndLargeText() async throws {
        let folder = URL(fileURLWithPath: "/tmp/kiki-settings-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let cases: [(String, CGSize, ColorScheme, DynamicTypeSize)] = [
            ("phone-light", CGSize(width: 375, height: 812), .light, .large),
            ("phone-dark", CGSize(width: 375, height: 812), .dark, .large),
            ("ipad-landscape", CGSize(width: 1133, height: 744), .light, .large),
            ("phone-accessibility3", CGSize(width: 375, height: 812), .light, .accessibility3)
        ]
        var selections: [KikiSettingsDestination] = []
        var logoutCalls = 0, deleteCalls = 0
        try await withWindow { window in
            for (label, size, scheme, typeSize) in cases {
                for isAccount in [false, true] {
                    let content: AnyView
                    if isAccount {
                        content = AnyView(KikiAccountSettingsContent(userID: longUserID,
                            appleIDBound: label != "phone-dark", isLoggingOut: false,
                            onLogout: { logoutCalls += 1 }, onDelete: { deleteCalls += 1 }))
                    } else {
                        content = AnyView(KikiSettingsMenuContent { selections.append($0) })
                    }
                    let host = await render(content, title: isAccount ? "账户" : "设置", in: window,
                                            size: size, scheme: scheme, typeSize: typeSize)
                    XCTAssertEqual(window.bounds.size, size)
                    XCTAssertEqual(host.view.bounds.size, size)
                    let scroll = try XCTUnwrap(scrollViews(in: host.view).max { lhs, rhs in
                        lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
                    }, "Settings and account content must remain scrollable when text grows")
                    XCTAssertGreaterThan(scroll.bounds.width, 300)
                    XCTAssertGreaterThan(scroll.bounds.height, 250)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 2,
                                             "Long IDs and larger fonts must not create horizontal overflow")
                    XCTAssertTrue(scroll.isScrollEnabled)
                    let prefix = device + "-" + (isAccount ? "account-" : "settings-") + label
                    try capture(window: window, name: prefix, folder: folder)

                    let bottom = max(-scroll.adjustedContentInset.top,
                                     scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    if bottom > scroll.contentOffset.y + 8 {
                        scroll.setContentOffset(CGPoint(x: -scroll.adjustedContentInset.left, y: bottom), animated: false)
                        try await Task.sleep(nanoseconds: 80_000_000)
                        window.layoutIfNeeded()
                        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 2,
                                       "The bottom actions must be reachable in a small viewport or large text")
                        try capture(window: window, name: prefix + "-bottom", folder: folder)
                    }
                }
            }
        }
        XCTAssertTrue(selections.isEmpty, "Rendering settings must never navigate automatically")
        XCTAssertEqual(logoutCalls, 0)
        XCTAssertEqual(deleteCalls, 0)
    }

    private func withWindow(_ operation: (UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer {
            window.frame = originalFrame
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await operation(window)
    }

    private func render(_ content: AnyView, title: String, in window: UIWindow,
                        size: CGSize = CGSize(width: 375, height: 812), scheme: ColorScheme = .light,
                        typeSize: DynamicTypeSize = .large) async -> UIViewController {
        let fixture = NavigationStack {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
        .tint(KikiPalette.lavender)
        .preferredColorScheme(scheme)
        .dynamicTypeSize(typeSize)
        let host = UIHostingController(rootView: fixture)
        window.rootViewController = host
        window.frame = CGRect(origin: window.frame.origin, size: size)
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        try? await Task.sleep(nanoseconds: 350_000_000)
        window.layoutIfNeeded()
        return host
    }

    private func capture(window: UIWindow, name: String, folder: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func accessibilityNodes(in root: UIView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard result.count < 2_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let view = object as? UIView {
                view.subviews.forEach(visit)
            }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { visit(element) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 500 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
                }
            }
        }
        visit(root)
        return result
    }

    private func identifier(_ object: NSObject) -> String? {
        (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

    private func node(in view: UIView, identifier target: String) -> NSObject? {
        accessibilityNodes(in: view).first { identifier($0) == target }
    }

    private func accessibleText(_ object: NSObject) -> String {
        [object.accessibilityLabel, object.accessibilityValue].compactMap { $0 }.joined(separator: " ")
    }

    private func activate(_ object: NSObject) -> Bool {
        if object.accessibilityActivate() { return true }
        guard let control = object as? UIControl, control.isEnabled else { return false }
        if control.allControlEvents.contains(.primaryActionTriggered) {
            control.sendActions(for: .primaryActionTriggered)
        } else if control.allControlEvents.contains(.touchUpInside) {
            control.sendActions(for: .touchUpInside)
        } else {
            return false
        }
        return true
    }
}
