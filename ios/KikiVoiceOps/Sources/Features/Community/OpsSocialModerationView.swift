import SwiftUI

struct OpsSocialModerationView: View {
    @ObservedObject var parent: OpsStore
    @ObservedObject var store: OpsSocialModerationStore
    @State private var selected: OpsSocialReport?
    @State private var restriction: OpsSocialRestriction?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("账号社区 · kiki.group").font(.subheadline.bold())
                Text("处理个人资料、动态、评论和私聊举报。社交禁言只限制发布与发送，不影响 Apple 登录或语音房间权限。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("举报状态", selection: Binding(get: { store.filter }, set: { value in Task { await store.load(filter: value) } })) {
                    ForEach(OpsReportFilter.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).disabled(store.isActing)
                if let error = store.error { Text(error).foregroundStyle(.red).font(.callout) }
                if let notice = store.notice { Text(notice).foregroundStyle(.indigo).font(.callout) }
                if let pending = store.pending {
                    OpsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("有一项结果待确认", systemImage: "clock.badge.exclamationmark").font(.headline)
                            Text("\(pending.request.action.title) · \(pending.request.reportID)").font(.caption)
                            Text(pending.request.note).font(.subheadline)
                            Button("恢复待确认操作") { Task { if await store.retryPending() { await store.load() } } }
                                .buttonStyle(.borderedProminent).disabled(store.isActing)
                            Text("复用原操作编号核对，避免超时后重复处置。待确认记录仅对原运维账号可见。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let page = store.page {
                    if !page.activeRestrictions.isEmpty {
                        Text("仍有效的社交禁言").font(.headline)
                        ForEach(page.activeRestrictions) { item in
                            Button { restriction = item } label: {
                                OpsCard {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.userName).font(.headline)
                                        Text(item.userID).font(.caption).foregroundStyle(.secondary)
                                        Text("至 \(Date(timeIntervalSince1970: item.until).formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                        Label("核对并解除", systemImage: "lock.open").font(.subheadline)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if page.reports.isEmpty {
                        ContentUnavailableView("没有符合条件的举报", systemImage: "checkmark.shield", description: Text("用户提交后会在这里显示。"))
                    }
                    ForEach(page.reports) { report in
                        Button { selected = report } label: {
                            OpsCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(report.reasonTitle).font(.headline)
                                        Spacer()
                                        Text(report.statusTitle).font(.caption).foregroundStyle(report.status == "pending" ? .orange : .secondary)
                                    }
                                    Text("\(report.typeTitle) · \(report.targetName)").font(.subheadline)
                                    Text(report.details.isEmpty ? "未填写补充说明" : report.details).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    if !report.evidence.media.isEmpty { Label("含 \(report.evidence.media.count) 张图片证据", systemImage: "photo").font(.caption) }
                                    Text(Date(timeIntervalSince1970: report.createdAt).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("socialReport.\(report.id)")
                    }
                    if page.nextCursor != nil { Button("加载更多") { Task { await store.load(more: true) } }.disabled(store.isLoading) }
                    Text("举报及按需证据最多保留 30 天；操作审计和幂等回执最多 90 天。这里只显示与举报关联的内容，不提供任意私聊浏览。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.isLoading { ProgressView("正在获取举报…").frame(maxWidth: .infinity) }
            }.padding(16)
        }.background(Color(.systemGroupedBackground)).navigationTitle("社交举报")
            .toolbar { Button { Task { await store.load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(store.isLoading || store.isActing) }
            .refreshable { await store.load() }
            .task { if store.page == nil { await store.load() } }
            .sheet(item: $selected) { report in NavigationStack { OpsSocialReportDetail(parent: parent, store: store, report: report) } }
            .sheet(item: $restriction) { value in NavigationStack { OpsSocialRestoreView(parent: parent, store: store, restriction: value) } }
    }
}

struct OpsSocialReportDetail: View {
    @ObservedObject var parent: OpsStore
    @ObservedObject var store: OpsSocialModerationStore
    let report: OpsSocialReport
    @Environment(\.dismiss) private var dismiss
    @State private var action = OpsSocialAction.warn
    @State private var duration = 3600
    @State private var note = ""
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var confirms = false
    private var request: OpsSocialActionRequest {
        OpsSocialActionRequest(requestID: requestID, reportID: report.id, action: action, durationSeconds: action == .restrictPosting ? duration : nil, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var available: Bool {
        parent.authenticated && parent.service == .community && parent.canAccessSelectedService
            && store.page?.reports.contains(where: { $0.id == report.id }) == true
    }
    var body: some View {
        Group {
            if !available { ContentUnavailableView("举报资料暂不可用", systemImage: "lock.shield", description: Text("请返回刷新并重新核对社区权限。")) }
            else {
                Form {
                    Section("举报信息") {
                        DataRow("对象", value: report.typeTitle)
                        DataRow("被举报用户", value: report.targetName)
                        Text(report.targetUserID).font(.caption.monospaced()).textSelection(.enabled)
                        DataRow("举报人", value: report.reporterName)
                        DataRow("原因", value: report.reasonTitle)
                        Text(report.details.isEmpty ? "未填写补充说明" : report.details)
                        Text(report.id).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Section("按需保留的证据") {
                        Text(report.evidence.text.isEmpty ? "没有文字证据" : report.evidence.text).textSelection(.enabled)
                        ForEach(report.evidence.media) { media in
                            if let data = store.images[media.id], let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                            } else {
                                Button { Task { await store.loadImage(media.id) } } label: { Label("查看图片证据", systemImage: "photo") }
                            }
                        }
                        Text("私聊证据由参与者举报后保存，仅限本案。图片按需读取，不写入系统相册。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("处理") {
                        Picker("处理方式", selection: $action) {
                            ForEach(OpsSocialAction.allCases.filter { option in
                                if option == .dismiss { return report.status == "pending" }
                                if option == .removeContent { return report.targetType != "profile" }
                                return true
                            }) { Text($0.title).tag($0) }
                        }
                        if action == .restrictPosting {
                            Picker("禁言期限", selection: $duration) {
                                Text("1 小时").tag(3600); Text("1 天").tag(86400); Text("7 天").tag(604800); Text("30 天").tag(2592000)
                            }
                            Text("禁止发布动态、评论和私聊；语音房间限制在语聊举报页单独处理。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("必填处理说明，最多 500 字", text: $note, axis: .vertical).lineLimit(3...6)
                        if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
                        Button("核对并处理") { confirms = true }.disabled(store.isActing || (try? request.validate()) == nil)
                        if store.isActing { ProgressView("正在处理…") }
                    }
                }
            }
        }.navigationTitle("社交举报详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(store.isActing) }
            .interactiveDismissDisabled(store.isActing)
            .onChange(of: note) { _, _ in requestID = UUID().uuidString.lowercased() }
            .onChange(of: action) { _, _ in requestID = UUID().uuidString.lowercased() }
            .onChange(of: duration) { _, _ in requestID = UUID().uuidString.lowercased() }
            .confirmationDialog("确认\(action.title)？", isPresented: $confirms, titleVisibility: .visible) {
                Button("确认处理", role: .destructive) {
                    let value = request
                    Task { if await store.act(value) { dismiss(); await store.load() } }
                }
                Button("取消", role: .cancel) { }
            } message: { Text("对象：\(report.targetName)\n理由：\(note)") }
    }
}

private struct OpsSocialRestoreView: View {
    @ObservedObject var parent: OpsStore
    @ObservedObject var store: OpsSocialModerationStore
    let restriction: OpsSocialRestriction
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var confirms = false
    var body: some View {
        Form {
            if parent.canAccessSelectedService, parent.service == .community,
               store.page?.activeRestrictions.contains(where: { $0.userID == restriction.userID && $0.sourceReportID == restriction.sourceReportID }) == true {
                Section("核对账号") { Text(restriction.userName); Text(restriction.userID).font(.caption.monospaced()).textSelection(.enabled) }
                Section("解除理由") {
                    TextField("必填，最多 500 字", text: $note, axis: .vertical).lineLimit(3...6)
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                    Button("核对并解除社交禁言") { confirms = true }.disabled(store.isActing || (try? request.validate()) == nil)
                }
            } else { Text("社区权限已变化，请关闭后重新登录核对。") }
        }.navigationTitle("解除社交禁言").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() }.disabled(store.isActing) }
            .onChange(of: note) { _, _ in requestID = UUID().uuidString.lowercased() }
            .confirmationDialog("确认解除该账号的社交禁言？", isPresented: $confirms) {
                Button("确认解除") {
                    let value = request
                    Task { if await store.act(value) { dismiss(); await store.load() } }
                }
            }
    }
    private var request: OpsSocialActionRequest {
        OpsSocialActionRequest(requestID: requestID, reportID: restriction.sourceReportID, action: .restoreUser, durationSeconds: nil, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
