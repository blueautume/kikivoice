import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import KikiVoiceOps

/// Server-issued sessions originate from the runner's real ES256/WebAuthn
/// ceremonies. This test validates server ACLs and native dashboard rendering;
/// it does not invoke or claim to verify the system Passkey sheet or Face ID.
final class VoiceOpsIntegrationTests: XCTestCase {
    @MainActor func testRealPasskeyIdentityPendingACLAndBothAuthorizedDashboards() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_OPS_PASSKEY_SESSIONS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需私密注入临时软件 WebAuthn 验收会话；系统通行密钥与 Face ID 另行人工确认。")
        }
        let fixtures: PublicFixtures
        do { fixtures = try JSONDecoder().decode(PublicFixtures.self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密验收会话格式不符合统一身份契约。"); return }
        let pending = try fixtures.pending.session()
        let authorized = try fixtures.authorized.session()
        let api = OpsIdentityAPI()
        do {
            let identity = try await api.me(session: pending)
            XCTAssertFalse(identity.permissions.voice); XCTAssertFalse(identity.permissions.account)
            guard !identity.needsName else { XCTFail("待授权验收身份需预先完成命名。"); return }
            let pendingStore = OpsStore(api: api, vault: MemoryVault(session: pending), authorizer: FixturePasskeyAuthorizer())
            pendingStore.setActive(true)
            try await waitFor { pendingStore.authenticated && !pendingStore.isRefreshing }
            XCTAssertFalse(pendingStore.canAccessSelectedService)
            XCTAssertNil(pendingStore.dashboard); XCTAssertNil(pendingStore.accountDashboard)
            try await attach(view: OpsRootView(store: pendingStore), name: "通行密钥运维-双服务待授权")
            for service in OpsService.allCases {
                do {
                    if service == .voice { _ = try await api.dashboard(session: pending) }
                    else { _ = try await api.accountDashboard(session: pending) }
                    XCTFail("未授权身份不可读取服务数据。")
                } catch { XCTAssertEqual(error as? OpsError, .forbidden) }
            }
            pendingStore.setActive(false)
            let identityWithGrants = try await api.me(session: authorized)
            XCTAssertTrue(identityWithGrants.permissions.voice); XCTAssertTrue(identityWithGrants.permissions.account)
            let store = OpsStore(api: api, vault: MemoryVault(session: authorized), authorizer: FixturePasskeyAuthorizer())
            store.setActive(true)
            try await waitFor { store.dashboard != nil && !store.isRefreshing }
            XCTAssertEqual(store.dashboard?.service.host, "furby.top")
            XCTAssertNil(store.accountDashboard)
            try await attach(view: NavigationStack { OverviewView(store: store) }, name: "统一运维-语聊运营")
            try await attach(view: NavigationStack { InfrastructureView(store: store) }, name: "统一运维-语聊运维")
            store.selectService(.account)
            try await waitFor { store.accountDashboard != nil && !store.isRefreshing }
            XCTAssertEqual(store.accountDashboard?.service.host, "kiki.group")
            XCTAssertNil(store.dashboard)
            try await attach(view: NavigationStack { AccountOverviewView(store: store) }, name: "统一运维-账号运营")
            try await attach(view: NavigationStack { AccountInfrastructureView(store: store) }, name: "统一运维-账号运维")
            store.setActive(false)
            try await api.logout(session: pending)
            try await api.logout(session: authorized)
            for session in [pending, authorized] {
                do { _ = try await api.me(session: session); XCTFail("退出后会话应失效。") }
                catch { XCTAssertEqual(error as? OpsError, .unauthenticated) }
            }
        } catch {
            try? await api.logout(session: pending); try? await api.logout(session: authorized)
            XCTFail("统一运维公网验收未完成，底层错误及凭据原文已隐藏。")
            throw NSError(domain: "OpsPasskeyIntegration", code: 1)
        }
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw NSError(domain: "OpsPasskeyIntegration", code: 2) }
    }
    @MainActor
    private func attach<V: View>(view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "截图必须使用真实前台场景")
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let controller = AppearedHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .systemBackground
        window.rootViewController = controller
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        for _ in 0..<100 {
            if controller.didAppear && controller.view.window === window { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.didAppear, "看板必须已实际进入可见窗口")
        guard controller.didAppear else { throw SnapshotError.notVisible }
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "窗口层级必须完成渲染")
        guard drewHierarchy else { throw SnapshotError.notRendered }
        let visibleRange = try imageLuminanceRange(image)
        XCTAssertGreaterThan(visibleRange, 32, "拒绝全黑或空白附件")
        guard visibleRange > 32 else { throw SnapshotError.blankImage }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func imageLuminanceRange(_ image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let width = 32, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var minimum = 255, maximum = 0
            for index in stride(from: 0, to: storage.count, by: 4) {
                let luminance = (Int(storage[index]) + Int(storage[index + 1]) + Int(storage[index + 2])) / 3
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
            return maximum - minimum
        }
    }

    private enum SnapshotError: Error { case notVisible, notRendered, blankImage }
}

private struct PublicFixtures: Decodable { let pending: Fixture; let authorized: Fixture }
private struct Fixture: Decodable {
    let token: String; let expiresAt: Double; let serviceID: String; let role: String; let account: OpsAccount
    func session() throws -> OpsSession {
        guard serviceID == "ops-identity", role == "member" else { throw OpsError.invalidResponse }
        try account.validate()
        let session = OpsSession(token: token, expiresAt: Date(timeIntervalSince1970: expiresAt))
        guard session.isValid() else { throw OpsError.expired }
        return session
    }
}
@MainActor private final class AppearedHostingController<Content: View>: UIHostingController<Content> {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); didAppear = true }
}
