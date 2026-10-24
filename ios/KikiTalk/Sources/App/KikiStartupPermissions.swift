import Foundation
import SwiftUI
import UIKit

/// A small public connectivity check, never an account or device registration.
@MainActor
protocol KikiStartupNetworkProbing {
    func check() async throws
}

/// iOS has no separate API for requesting ordinary internet access. A public
/// HTTPS request lets the operating system present its network prompt where
/// applicable, and verifies that the service is reachable before login starts.
@MainActor
final class KikiStartupHTTPSProbe: KikiStartupNetworkProbing {
    private static let endpoint = URL(string: "https://kiki.group/health")!
    private struct Health: Decodable { let status: String }

    func check() async throws {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.allowsCellularAccess = true
        // Use system certificate validation and the existing no-redirect policy.
        let session = URLSession(configuration: configuration, delegate: KikiHTTPSDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("kiki-Startup/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url == Self.endpoint,
              response.mimeType?.lowercased() == "application/json" else {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4096 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: data), health.status == "ok" else {
            throw URLError(.badServerResponse)
        }
    }
}

/// This coordinator exists before the business store. It never accesses a
/// Keychain identifier, creates RTC, registers APNs, uploads a token or changes
/// an account preference. Only current explicit consent can start its work.
@MainActor
final class KikiStartupPermissions: ObservableObject {
    enum Stage: Equatable {
        case idle, waitingForForeground, checkingNetwork, requestingNotifications, ready, failed
    }

    @Published private(set) var stage = Stage.idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var notificationNotice: String?
    @Published private(set) var notificationPermission = KikiPushPermission.unknown
    var isReady: Bool { stage == .ready }
    func isReady(for consent: KikiConsentStore) -> Bool {
        isReady && consent.hasCurrentConsent && readyReceipt == consent.receipt
    }
    var isBusy: Bool {
        stage == .waitingForForeground || stage == .checkingNetwork || stage == .requestingNotifications
    }

    private let network: any KikiStartupNetworkProbing
    private let notifications: any KikiPushSystem
    private let waitForForeground: @MainActor () async throws -> Void
    private var operation = UUID()
    private var work: Task<Void, Never>?
    private var workingReceipt: KikiConsentStore.Receipt?
    private var readyReceipt: KikiConsentStore.Receipt?
    // Cancelling the app flow cannot dismiss an operating-system alert. A new
    // flow joins that existing request instead of asking the system twice.
    private var notificationRequest: (id: UUID, task: Task<Void, Error>)?

    init(network: (any KikiStartupNetworkProbing)? = nil,
         notifications: (any KikiPushSystem)? = nil,
         waitForForeground: (@MainActor () async throws -> Void)? = nil) {
        self.network = network ?? KikiStartupHTTPSProbe()
        self.notifications = notifications ?? KikiNativePushSystem()
        self.waitForForeground = waitForForeground ?? {
            // A cancellable wait avoids stacking the notification prompt while
            // the network prompt has temporarily made the app inactive.
            while UIApplication.shared.applicationState != .active {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            try Task.checkCancellation()
        }
    }

    func begin(consent: KikiConsentStore) async {
        guard !Task.isCancelled else { cancel(); return }
        guard consent.hasCurrentConsent, let receipt = consent.receipt else {
            cancel()
            return
        }
        if isReady, readyReceipt == receipt { return }
        if let work {
            if workingReceipt == receipt {
                await awaitWork(work, operation: operation)
                return
            }
            cancel()
        }
        let id = UUID()
        operation = id
        readyReceipt = nil
        errorMessage = nil
        notificationNotice = nil
        let work = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.prepare(consent: consent, receipt: receipt, operation: id)
        }
        self.work = work
        workingReceipt = receipt
        await awaitWork(work, operation: id)
        if operation == id { self.work = nil; workingReceipt = nil }
    }

    func retry(consent: KikiConsentStore) async { await begin(consent: consent) }

    func cancel() {
        operation = UUID()
        work?.cancel()
        work = nil
        workingReceipt = nil
        readyReceipt = nil
        stage = .idle
        errorMessage = nil
        notificationNotice = nil
        notificationPermission = .unknown
    }

    private func awaitWork(_ work: Task<Void, Never>, operation id: UUID) async {
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            Task { @MainActor [weak self] in
                // The successful transition removes its preparation view. That
                // view's task cancellation must not erase completed readiness.
                guard let self, self.operation == id, !self.isReady else { return }
                self.cancel()
            }
        }
    }

    private func requireCurrent(_ consent: KikiConsentStore, receipt: KikiConsentStore.Receipt, operation id: UUID) throws {
        try Task.checkCancellation()
        guard operation == id, consent.hasCurrentConsent, consent.receipt == receipt else {
            throw CancellationError()
        }
    }

    private func foreground(_ consent: KikiConsentStore, receipt: KikiConsentStore.Receipt, operation id: UUID) async throws {
        try requireCurrent(consent, receipt: receipt, operation: id)
        stage = .waitingForForeground
        try await waitForForeground()
        try requireCurrent(consent, receipt: receipt, operation: id)
    }

    private func requestNotifications(_ consent: KikiConsentStore, receipt: KikiConsentStore.Receipt, operation id: UUID) async throws {
        if let existing = notificationRequest {
            try await existing.task.value
            return
        }
        let requestID = UUID()
        let task = Task<Void, Error> { [self] in
            try requireCurrent(consent, receipt: receipt, operation: id)
            try await notifications.requestPermission()
        }
        notificationRequest = (requestID, task)
        defer { if notificationRequest?.id == requestID { notificationRequest = nil } }
        try await task.value
    }

    private func prepare(consent: KikiConsentStore, receipt: KikiConsentStore.Receipt, operation id: UUID) async {
        do {
            try await foreground(consent, receipt: receipt, operation: id)
            stage = .checkingNetwork
            try await network.check()
            try requireCurrent(consent, receipt: receipt, operation: id)
            try await foreground(consent, receipt: receipt, operation: id)
            stage = .requestingNotifications
            notificationPermission = await notifications.permission()
            try requireCurrent(consent, receipt: receipt, operation: id)
            if notificationPermission == .notDetermined {
                try await foreground(consent, receipt: receipt, operation: id)
                stage = .requestingNotifications
                do {
                    try await requestNotifications(consent, receipt: receipt, operation: id)
                } catch {
                    try requireCurrent(consent, receipt: receipt, operation: id)
                    notificationNotice = "暂时无法开启通知，你仍可继续登录，之后在系统设置中调整。"
                }
                try requireCurrent(consent, receipt: receipt, operation: id)
                notificationPermission = await notifications.permission()
                try requireCurrent(consent, receipt: receipt, operation: id)
            }
            // Declining an optional notification permission never blocks login.
            readyReceipt = receipt
            stage = .ready
        } catch is CancellationError {
            guard operation == id else { return }
            readyReceipt = nil
            stage = .idle
            errorMessage = nil
        } catch {
            guard operation == id else { return }
            readyReceipt = nil
            stage = .failed
            errorMessage = "暂时无法连接服务，请检查网络连接后重试，也可以前往系统设置检查网络访问。"
        }
    }
}
