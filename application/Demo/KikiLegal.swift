import Foundation
import CryptoKit
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
    private(set) var validatedData: Data?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, privacyVersion, termsVersion, documentHash, updatedAt, minimumAge, `operator`, documents
    }

    var versions: KikiLegalVersions {
        KikiLegalVersions(privacyVersion: privacyVersion, termsVersion: termsVersion, documentHash: documentHash)
    }

    var isValid: Bool {
        schemaVersion == 1 && minimumAge == 18 && !privacyVersion.isEmpty && !termsVersion.isEmpty
        && documentHash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
        && Set(documents.map(\.id)) == Set(["privacy", "terms", "sdk", "permissions"])
        && documents.count == 4
        && documents.allSatisfy { !$0.title.isEmpty && !$0.version.isEmpty && !$0.sections.isEmpty && $0.sections.allSatisfy { !$0.title.isEmpty && !$0.paragraphs.isEmpty && $0.paragraphs.allSatisfy { !$0.isEmpty } } }
        && documents.first(where: { $0.id == "privacy" })?.version == privacyVersion
        && documents.first(where: { $0.id == "terms" })?.version == termsVersion
    }

    static var bundled: KikiLegalBundle? {
        guard let url = Bundle.main.url(forResource: "KikiLegalDocuments", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? decodeValidated(data) else { return nil }
        return value
    }

    /// Match the server's UTF-8 canonical JSON hash. The hash binds the receipt
    /// to the complete text; authenticity comes from the fixed HTTPS endpoint.
    static func decodeValidated(_ data: Data) throws -> KikiLegalBundle {
        guard !data.isEmpty, data.count <= 512 * 1024,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true,
              !["draft", "草稿"].contains((object["status"] as? String ?? "").lowercased()) else {
            throw KikiAPIError.security("协议内容无法验证，请重新获取。")
        }
        var value = try JSONDecoder().decode(KikiLegalBundle.self, from: data)
        guard value.isValid else { throw KikiAPIError.security("协议内容不完整，请重新获取。") }
        object.removeValue(forKey: "documentHash")
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        guard digest == value.documentHash else {
            throw KikiAPIError.security("协议正文与校验值不一致，请重新获取。")
        }
        value.validatedData = data
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

/// Public legal text is fetched without account credentials. No business SDK or
/// identity is initialized before the user's explicit, versioned decision.
@MainActor
final class KikiConsentStore: ObservableObject {
    static let shared = KikiConsentStore()
    static let storageKey = "kiki.legalConsent.v1"
    static let documentsStorageKey = "kiki.legalDocuments.v1"

    struct Receipt: Codable, Equatable {
        enum Status: String, Codable { case accepted, withdrawing, updateRequired }
        var versions: KikiLegalVersions
        var acceptedAt: Date
        var adultConfirmed: Bool
        var status: Status
        var requiredVersions: KikiLegalVersions?
        var serverWithdrawalConfirmed: Bool?
    }

    @Published private(set) var documents: KikiLegalBundle?
    @Published private(set) var isRefreshingDocuments = false
    @Published private(set) var documentError: String?
    @Published private(set) var hasVerifiedRemoteDocuments = false
    @Published private(set) var receipt: Receipt?
    @Published private(set) var withdrawalInProgress = false
    @Published private(set) var withdrawalError: String?
    @Published private(set) var notice: String?
    @Published private(set) var serviceTransitionInProgress = false
    private let defaults: UserDefaults
    private let identity: any KikiIdentityStoring
    private let apiProvider: () -> KikiAccountAPIClient
    private let requiresRemoteDocuments: Bool
    private var pendingTeardown: (() async throws -> Void)?

    init(documents: KikiLegalBundle? = KikiLegalBundle.bundled, defaults: UserDefaults = .standard,
         identity: any KikiIdentityStoring = KikiKeychainStorage(), apiProvider: @escaping () -> KikiAccountAPIClient = { .shared },
         requiresRemoteDocuments: Bool = true) {
        // A saved server copy is only an offline reader, never proof of the
        // server's current requirements after a restart or an over-install.
        let cached = defaults.data(forKey: Self.documentsStorageKey).flatMap { try? KikiLegalBundle.decodeValidated($0) }
        self.documents = cached ?? (documents?.isValid == true ? documents : nil)
        self.defaults = defaults
        self.identity = identity
        self.apiProvider = apiProvider
        self.requiresRemoteDocuments = requiresRemoteDocuments
        if let data = defaults.data(forKey: Self.storageKey) {
            receipt = try? JSONDecoder().decode(Receipt.self, from: data)
        }
    }

    var isWithdrawalPending: Bool { receipt?.status == .withdrawing }
    var requiresAppUpdate: Bool {
        false // Content updates are downloaded; they do not require a binary update.
    }
    var requiresDocumentRefresh: Bool {
        guard let documents else { return true }
        if requiresRemoteDocuments && !hasVerifiedRemoteDocuments { return true }
        guard let receipt, receipt.status == .updateRequired else { return false }
        return receipt.requiredVersions == nil || receipt.requiredVersions != documents.versions
    }
    var hasCurrentConsent: Bool {
        guard let receipt, let documents else { return false }
        return (!requiresRemoteDocuments || hasVerifiedRemoteDocuments)
            && receipt.status == .accepted && receipt.adultConfirmed && receipt.versions == documents.versions
    }
    var canAccept: Bool { documents != nil && !requiresDocumentRefresh && !isRefreshingDocuments && !isWithdrawalPending && !serviceTransitionInProgress }

    func refreshDocuments() async {
        guard !isRefreshingDocuments, !isWithdrawalPending, !serviceTransitionInProgress else { return }
        isRefreshingDocuments = true
        documentError = nil
        defer { isRefreshingDocuments = false }
        do {
            let current = try await apiProvider().legalDocuments()
            try Task.checkCancellation()
            guard !isWithdrawalPending, !serviceTransitionInProgress else { return }
            guard let data = current.validatedData else { throw KikiAPIError.invalidResponse }
            defaults.set(data, forKey: Self.documentsStorageKey)
            documents = current
            hasVerifiedRemoteDocuments = true
            // Persisted updateRequired can describe an earlier deployment.
            // Only the current server snapshot decides which text to present.
            if var pending = receipt, pending.status == .updateRequired {
                pending.requiredVersions = current.versions
                save(pending)
                notice = "协议已更新，请阅读当前完整文本后重新确认。"
            }
        } catch is CancellationError { }
        catch { documentError = "暂时无法获取最新协议：\(error.localizedDescription)" }
    }

    func setServiceTransition(_ active: Bool) { serviceTransitionInProgress = active }

    /// Invoked only by the disclosed “同意并继续” action. The action also
    /// confirms the adjacent 18+ declaration; login never writes this receipt.
    func accept() throws {
        guard canAccept, let documents else {
            throw KikiAPIError.security("请先阅读当前协议，确认同意且已满 18 周岁后继续。")
        }
        // Repeated UI delivery must not replace an already-current decision.
        if !hasCurrentConsent {
            save(Receipt(versions: documents.versions, acceptedAt: Date(), adultConfirmed: true, status: .accepted))
        }
        notice = nil
    }

    /// A server acceptance can only be derived from the persisted, current
    /// decision. Calling login, reopening the app or dismissing Apple UI cannot
    /// manufacture consent or require a second confirmation.
    func acceptance() throws -> KikiLegalAcceptance {
        guard hasCurrentConsent, let documents else {
            throw KikiAPIError.security("请先阅读并同意当前协议，确认已满 18 周岁。")
        }
        return KikiLegalAcceptance(versions: documents.versions, accepted: true, adultConfirmed: true)
    }

    // Compatibility for existing internal callers/tests; no UI uses checkboxes.
    func accept(agreed: Bool, adultConfirmed: Bool) throws {
        guard agreed, adultConfirmed else {
            throw KikiAPIError.security("请先阅读并同意当前协议，确认已满 18 周岁。")
        }
        try accept()
    }

    func acceptance(agreed: Bool, adultConfirmed: Bool) throws -> KikiLegalAcceptance {
        guard agreed, adultConfirmed else {
            throw KikiAPIError.security("请先阅读并同意当前协议，确认已满 18 周岁。")
        }
        return try acceptance()
    }

    func verify(_ status: KikiLegalStatus) throws {
        guard status.requiredVersions == documents?.versions, !status.requiresAcceptance else {
            throw KikiAPIError.legalUpdateRequired("服务器协议已更新或尚未确认，请重新核对协议。", status.requiredVersions)
        }
    }

    func requireUpdatedDocuments(_ required: KikiLegalVersions?, message: String) {
        guard !isWithdrawalPending else { return }
        hasVerifiedRemoteDocuments = false
        let versions = documents?.versions ?? receipt?.versions ?? KikiLegalVersions(privacyVersion: "", termsVersion: "", documentHash: "")
        save(Receipt(versions: versions, acceptedAt: Date(), adultConfirmed: false, status: .updateRequired, requiredVersions: required))
        notice = "协议已更新，请获取并阅读当前完整文本后重新确认。"
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
