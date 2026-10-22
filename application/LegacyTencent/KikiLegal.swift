import Foundation
import SwiftUI

struct KikiLegalVersions: Codable, Equatable {
    let privacyVersion: String
    let termsVersion: String
    let documentHash: String
}

struct KikiLegalAcceptance: Codable, Equatable {
    let privacyVersion: String
    let termsVersion: String
    let documentHash: String
    let accepted: Bool
    let adultConfirmed: Bool

    init(versions: KikiLegalVersions, accepted: Bool, adultConfirmed: Bool) {
        privacyVersion = versions.privacyVersion
        termsVersion = versions.termsVersion
        documentHash = versions.documentHash
        self.accepted = accepted
        self.adultConfirmed = adultConfirmed
    }
}

struct KikiLegalStatus: Decodable {
    struct ServerReceipt: Decodable {
        let privacyVersion: String
        let termsVersion: String
        let documentHash: String
        let acceptedAt: Int?
        let withdrawnAt: Int?
    }
    let requiredVersions: KikiLegalVersions
    let requiresAcceptance: Bool
    let legalConsent: ServerReceipt?
}

struct KikiLegalBundle: Decodable {
    struct Operator: Decodable {
        let name: String
        let type: String
        let email: String
    }
    struct Document: Decodable, Identifiable {
        struct Section: Decodable {
            let title: String
            let paragraphs: [String]
        }
        let id: String
        let title: String
        let version: String
        let sections: [Section]
    }
    let schemaVersion: Int
    let privacyVersion: String
    let termsVersion: String
    let documentHash: String
    let updatedAt: String
    let minimumAge: Int
    let `operator`: Operator
    let documents: [Document]

    var versions: KikiLegalVersions {
        KikiLegalVersions(privacyVersion: privacyVersion, termsVersion: termsVersion, documentHash: documentHash)
    }

    var isValid: Bool {
        schemaVersion == 1 && minimumAge == 18 && !privacyVersion.isEmpty && !termsVersion.isEmpty
        && documentHash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
        && Set(documents.map(\.id)) == Set(["privacy", "terms", "sdk", "permissions"])
        && documents.count == 4
        && documents.allSatisfy { !$0.title.isEmpty && !$0.sections.isEmpty && $0.sections.allSatisfy { !$0.paragraphs.isEmpty } }
        && documents.first(where: { $0.id == "privacy" })?.version == privacyVersion
        && documents.first(where: { $0.id == "terms" })?.version == termsVersion
    }

    static var bundled: KikiLegalBundle? {
        guard let url = Bundle.main.url(forResource: "KikiLegalDocuments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(KikiLegalBundle.self, from: data), value.isValid else { return nil }
        return value
    }
}

protocol KikiIdentityStoring {
    func read(_ key: String) -> String?
    func write(_ value: String, key: String) throws
    func remove(_ key: String)
}

struct KikiKeychainStorage: KikiIdentityStoring {
    func read(_ key: String) -> String? { KikiKeychain.read(key) }
    func write(_ value: String, key: String) throws { try KikiKeychain.write(value, key: key) }
    func remove(_ key: String) { KikiKeychain.remove(key) }
}

/// The only state loaded before consent is a local, versioned consent receipt.
/// This class does not initialize networking, an SDK, or a device identifier.
@MainActor
final class KikiConsentStore: ObservableObject {
    static let shared = KikiConsentStore()
    static let storageKey = "kiki.legalConsent.v1"

    struct Receipt: Codable, Equatable {
        enum Status: String, Codable { case accepted, withdrawing, updateRequired }
        var versions: KikiLegalVersions
        var acceptedAt: Date
        var adultConfirmed: Bool
        var status: Status
        var requiredVersions: KikiLegalVersions?
        var serverWithdrawalConfirmed: Bool?
    }

    let documents: KikiLegalBundle?
    @Published private(set) var receipt: Receipt?
    @Published private(set) var withdrawalInProgress = false
    @Published private(set) var withdrawalError: String?
    @Published private(set) var notice: String?
    @Published private(set) var serviceTransitionInProgress = false
    private let defaults: UserDefaults
    private let identity: any KikiIdentityStoring
    private let apiProvider: () -> KikiAPIClient
    private var pendingTeardown: (() async throws -> Void)?

    init(documents: KikiLegalBundle? = KikiLegalBundle.bundled, defaults: UserDefaults = .standard,
         identity: any KikiIdentityStoring = KikiKeychainStorage(), apiProvider: @escaping () -> KikiAPIClient = { .shared }) {
        self.documents = documents?.isValid == true ? documents : nil
        self.defaults = defaults
        self.identity = identity
        self.apiProvider = apiProvider
        if let data = defaults.data(forKey: Self.storageKey) {
            receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        }
    }

    var isWithdrawalPending: Bool { receipt?.status == .withdrawing }
    var requiresAppUpdate: Bool {
        guard let receipt, receipt.status == .updateRequired else { return false }
        return receipt.requiredVersions == nil || receipt.requiredVersions != documents?.versions
    }
    var hasCurrentConsent: Bool {
        guard let receipt, let documents else { return false }
        return receipt.status == .accepted && receipt.adultConfirmed && receipt.versions == documents.versions
    }
    var canAccept: Bool { documents != nil && !requiresAppUpdate && !isWithdrawalPending && !serviceTransitionInProgress }

    func setServiceTransition(_ active: Bool) { serviceTransitionInProgress = active }

    func accept(agreed: Bool, adultConfirmed: Bool) throws {
        guard agreed, adultConfirmed, canAccept, let documents else {
            throw KikiAPIError.security("请阅读并勾选协议，确认已满 18 周岁后继续。")
        }
        save(Receipt(versions: documents.versions, acceptedAt: Date(), adultConfirmed: true, status: .accepted))
        notice = nil
    }

    func acceptance(agreed: Bool, adultConfirmed: Bool) throws -> KikiLegalAcceptance {
        guard hasCurrentConsent, agreed, adultConfirmed, let documents else {
            throw KikiAPIError.security("请先阅读并同意当前协议，确认已满 18 周岁。")
        }
        return KikiLegalAcceptance(versions: documents.versions, accepted: true, adultConfirmed: true)
    }

    func verify(_ status: KikiLegalStatus) throws {
        guard status.requiredVersions == documents?.versions, !status.requiresAcceptance else {
            throw KikiAPIError.legalUpdateRequired("服务器协议已更新或尚未确认，请重新核对协议。", status.requiredVersions)
        }
    }

    func requireUpdatedDocuments(_ required: KikiLegalVersions?, message: String) {
        guard !isWithdrawalPending else { return }
        let versions = documents?.versions ?? receipt?.versions ?? KikiLegalVersions(privacyVersion: "", termsVersion: "", documentHash: "")
        save(Receipt(versions: versions, acceptedAt: Date(), adultConfirmed: false, status: .updateRequired, requiredVersions: required))
        notice = message
    }

    func withdraw(teardown: @escaping () async throws -> Void) async {
        guard !withdrawalInProgress, let old = receipt else { return }
        pendingTeardown = teardown
        var pending = old
        pending.status = .withdrawing
        pending.serverWithdrawalConfirmed = identity.read("sessionToken") == nil
        save(pending)
        await retryWithdrawal()
    }

    /// A pending withdrawal survives termination. A cold launch can retry the
    /// authenticated withdrawal without constructing or logging in any SDK.
    func retryWithdrawal() async {
        guard isWithdrawalPending, !withdrawalInProgress else { return }
        withdrawalInProgress = true
        withdrawalError = nil
        defer { withdrawalInProgress = false }
        var failures: [String] = []
        if let teardown = pendingTeardown {
            do { try await teardown(); pendingTeardown = nil }
            catch { failures.append("音视频退出未完成：\(error.localizedDescription)") }
        }
        if receipt?.serverWithdrawalConfirmed != true {
            if let token = identity.read("sessionToken") {
                do {
                    try await apiProvider().withdrawLegalConsent(token: token)
                    if var pending = receipt {
                        pending.serverWithdrawalConfirmed = true
                        save(pending)
                    }
                } catch { failures.append("服务器撤回未获确认：\(error.localizedDescription)") }
            } else { failures.append("缺少服务器撤回凭据，无法确认账号撤回结果，请联系开发者处理。") }
        }
        if receipt?.serverWithdrawalConfirmed == true {
            identity.remove("sessionToken")
            identity.remove("lastUserID")
            identity.remove("appleSubject")
            identity.remove("appleSessionVersion")
            identity.remove("deviceSecret")
            identity.remove("applePendingLogouts")
            identity.remove("applePendingRevocations")
        }
        if failures.isEmpty {
            // A later sign-in always starts a fresh system Apple authorization.
            save(nil)
            notice = "已撤回同意并退出登录。你仍可离线阅读协议；账号注销请在重新同意并登录后操作。"
        } else {
            withdrawalError = "撤回尚未全部完成。\(failures.joined(separator: "；"))。本机已停止业务服务，请重试。"
        }
    }

    private func save(_ value: Receipt?) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.storageKey)
        } else { defaults.removeObject(forKey: Self.storageKey) }
        receipt = value
    }
}
