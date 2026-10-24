import SwiftUI

struct OpsCommunityView: View {
    @ObservedObject var store: OpsStore
    @State private var selectedReport: OpsReport?
    @State private var selectedRestriction: OpsActiveRestriction?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("语聊服务 · furby.top").font(.subheadline.bold())
                Text("社区权限单独授权。所有处置记录操作者编号；语聊限制不影响 Apple 账号登录、设置及注销。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("举报状态", selection: Binding(get: { store.moderationFilter }, set: { store.selectModerationFilter($0) })) {
                    ForEach(OpsReportFilter.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).disabled(store.isModerating)
                if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
                if let notice = store.moderationNotice { Text(notice).font(.callout).foregroundStyle(.indigo) }
                if let pending = store.pendingModeration {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("有一项结果待确认", systemImage: "clock.badge.exclamationmark").font(.headline)
                            Text("\(pending.request.action.label) · \(pending.request.reportID)").font(.caption)
                            Text("\(pending.request.note)").font(.subheadline)
                            Text("恢复操作会使用原编号核对服务器；已执行的操作不会重复处罚。请先完成核对再处理其他举报。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("恢复待确认操作") { Task { _ = await store.retryPendingModeration() } }
                                .buttonStyle(.borderedProminent).disabled(store.isModerating)
                        }
                    }
                }
                if let page = store.moderationPage {
                    if page.activeRestrictionsTruncated == true {
                        Text("有效限制超过当前展示上限，列表仅含部分记录，请联系负责人核查。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let restrictions = page.activeRestrictions, !restrictions.isEmpty {
                        Text("仍有效的语聊限制").font(.headline)
                        ForEach(restrictions) { restriction in
                            Button { selectedRestriction = restriction } label: {
                                OpsCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(restriction.accountLabel).font(.subheadline.monospaced()).lineLimit(2)
                                        ForEach(restrictionDates(restriction), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                        Label("核对并解除限制", systemImage: "lock.open").font(.subheadline)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                        Text("证据到期后仍可解除有效限制；这里仅显示账号编号与限制期限。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if page.reports.isEmpty {
                        ContentUnavailableView("没有符合条件的举报", systemImage: "checkmark.shield", description: Text("用户提交后会在这里显示。"))
                    }
                    ForEach(page.reports) { report in
                        Button { selectedReport = report } label: {
                            OpsCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(report.reasonLabel).font(.headline)
                                        Spacer()
                                        Text(report.statusLabel).font(.caption).foregroundStyle(report.status == "pending" ? .orange : .secondary)
                                    }
                                    Text("\(report.typeLabel) · \(report.roomTitle)").font(.subheadline).lineLimit(2)
                                    if let name = report.targetName { Text("被举报用户：\(name)").font(.subheadline).lineLimit(1) }
                                    Text(report.details.isEmpty ? "未填写补充说明" : report.details).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    Text(Date(timeIntervalSince1970: report.createdAt).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("opsReport.\(report.id)")
                    }
                    Text("待处理按提交先后显示 50 条，处理后显示下一批；其他筛选显示最新 50 条。举报证据保留 \(page.retentionDays) 天；这里没有录音或自动语音审核结果。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.isRefreshing { ProgressView("正在获取举报…").frame(maxWidth: .infinity) }
                else { ContentUnavailableView("等待举报数据", systemImage: "shield", description: Text("下拉或点击刷新重试。")) }
            }.padding(16)
        }
        .background(Color(.systemGroupedBackground)).navigationTitle("社区管理")
        .toolbar { Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(store.isRefreshing || store.isModerating) }
        .refreshable { await store.refresh() }
        .sheet(item: $selectedReport) { report in NavigationStack { OpsReportDetail(store: store, report: report) } }
        .sheet(item: $selectedRestriction) { restriction in NavigationStack { OpsRestrictionRestoreView(store: store, restriction: restriction) } }
    }
    private func restrictionDates(_ restriction: OpsActiveRestriction) -> [String] {
        [("文字禁言", restriction.chatMutedUntil), ("禁麦", restriction.voiceMutedUntil), ("语聊封禁", restriction.bannedUntil)]
            .compactMap { title, value in value.map { "\(title)至 \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened))" } }
    }
}

private struct OpsRestrictionRestoreView: View {
    @ObservedObject var store: OpsStore
    let restriction: OpsActiveRestriction
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var confirms = false
    @State private var requestID = UUID().uuidString.lowercased()
    private var request: OpsModerationRequest {
        OpsModerationRequest(requestID: requestID, reportID: restriction.reportID, action: .restoreUser,
                             durationSeconds: nil, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var body: some View {
        Form {
            Section("核对账号") {
                Text(restriction.accountLabel).textSelection(.enabled)
                Text("审核编号：\(restriction.targetUserID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("关联处置：\(restriction.reportID)").font(.caption).textSelection(.enabled)
                Text("本操作解除该账号现有的语聊封禁、文字禁言及禁麦限制，不恢复已关闭的房间。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("解除理由") {
                TextField("必填，最多 500 字", text: $note, axis: .vertical).lineLimit(3...7)
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Button("核对并解除限制") { confirms = true }
                    .disabled(store.isModerating || (try? request.validate()) == nil)
                if store.isModerating { ProgressView("正在处理…") }
            }
        }.navigationTitle("解除语聊限制").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(store.isModerating) }
            .interactiveDismissDisabled(store.isModerating)
            .onChange(of: note) { _, _ in requestID = UUID().uuidString.lowercased() }
            .confirmationDialog("确认解除该账号的全部语聊限制？", isPresented: $confirms, titleVisibility: .visible) {
                Button("确认解除") {
                    let submitted = request
                    Task { if await store.moderate(submitted) { dismiss() } }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("账号：\(restriction.accountLabel)\n理由：\(note)") }
    }
}

struct OpsReportDetail: View {
    @ObservedObject var store: OpsStore
    let report: OpsReport
    @Environment(\.dismiss) private var dismiss
    @State private var action: OpsModerationAction = .warn
    @State private var duration = 86400
    @State private var note = ""
    @State private var confirms = false
    @State private var requestID = UUID().uuidString.lowercased()
    private var request: OpsModerationRequest {
        OpsModerationRequest(requestID: requestID, reportID: report.id, action: action,
                             durationSeconds: action.requiresDuration ? duration : nil,
                             note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var canSubmit: Bool { report.permits(action) && (try? request.validate()) != nil && !store.isModerating }
    var body: some View {
        Form {
            Section("举报信息") {
                LabeledContent("对象", value: report.typeLabel)
                LabeledContent("原因", value: report.reasonLabel)
                LabeledContent("状态", value: report.statusLabel)
                Text("编号：\(report.id)").font(.caption).textSelection(.enabled)
                Text("房间：\(report.roomTitle)\n\(report.roomID)").font(.subheadline).textSelection(.enabled)
                if let id = report.targetUserID {
                    Text("被举报人：\(report.targetName ?? "未知")\n\(report.targetLabel ?? id)").font(.subheadline).textSelection(.enabled)
                    Text("审核编号：\(id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("举报人：\(report.reporterName)\n\(report.reporterLabel)").font(.caption).textSelection(.enabled)
                if !report.details.isEmpty { Text(report.details).textSelection(.enabled) }
            }
            if let excerpt = report.messageExcerpt, !excerpt.isEmpty {
                Section("提交时的消息证据") { Text(excerpt).textSelection(.enabled) }
            }
            Section("处理方式") {
                Picker("操作", selection: $action) {
                    ForEach(OpsModerationAction.allCases.filter { report.permits($0) }) { Text($0.label).tag($0) }
                }
                if action.requiresDuration {
                    Picker("期限", selection: $duration) {
                        Text("1 小时").tag(3600); Text("24 小时").tag(86400)
                        Text("7 天").tag(604800); Text("30 天").tag(2592000)
                    }
                }
                TextField("处理说明（必填，最多 500 字）", text: $note, axis: .vertical).lineLimit(3...7)
                    .accessibilityIdentifier("opsModerationNote")
                Text("警告与限制通知会发送给相关用户，请勿在说明中填写举报人的敏感信息。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.error { Text(error).foregroundStyle(.red) }
                Button(action.label, role: action == .dismiss || action == .restoreUser ? nil : .destructive) { confirms = true }
                    .disabled(!canSubmit).accessibilityIdentifier("opsModerationSubmit")
                if store.isModerating { ProgressView("正在处理…") }
            }.disabled(store.isModerating)
            Section {
                Text("证据到期：\(Date(timeIntervalSince1970: report.evidenceExpiresAt).formatted(date: .abbreviated, time: .shortened))")
                Text("处置范围为语聊服务。临时限制到期自动解除；关闭房间会让房内全部成员离开。")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("处理举报").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(store.isModerating) }
            ToolbarItem(placement: .confirmationAction) { Button("提交") { confirms = true }.disabled(!canSubmit) }
        }
        .interactiveDismissDisabled(store.isModerating)
        .onAppear { if !report.permits(action) { action = .closeRoom } }
        .onChange(of: action) { _, _ in requestID = UUID().uuidString.lowercased() }
        .onChange(of: duration) { _, _ in requestID = UUID().uuidString.lowercased() }
        .onChange(of: note) { _, _ in requestID = UUID().uuidString.lowercased() }
        .confirmationDialog("确认\(action.label)？", isPresented: $confirms, titleVisibility: .visible) {
            Button("确认处理", role: action == .dismiss || action == .restoreUser ? nil : .destructive) {
                let submitted = request
                Task { if await store.moderate(submitted) { dismiss() } }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("房间：\(report.roomTitle)\n用户：\(report.targetName ?? "房间成员")\n\(action.requiresDuration ? "期限：\(duration / 3600) 小时\n" : "")说明：\(note)")
        }
    }
}
