import LiveKit
import SwiftUI

struct KikiRoomDiagnosticsView: View {
    @ObservedObject var rtc: KikiRTCService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(KikiL10n.text("当前连接")) {
                    LabeledContent(KikiL10n.text("连接状态"), value: rtc.isRecovering ? KikiL10n.text("恢复并校准中") : (rtc.connectionState == .connected ? KikiL10n.text("已连接") : KikiL10n.text("已断开")))
                    LabeledContent(KikiL10n.text("本机连接质量"), value: rtc.connectionQuality.kikiLabel)
                    LabeledContent(KikiL10n.text("本次入房重连次数"), value: String(rtc.reconnectCount))
                    LabeledContent(KikiL10n.text("媒体往返延迟"), value: metric(rtc.networkMetrics.rttMs, suffix: " ms"))
                    LabeledContent(KikiL10n.text("接收最大抖动"), value: metric(rtc.networkMetrics.jitterMs, suffix: " ms"))
                    LabeledContent(KikiL10n.text("接收累计丢包"), value: metric(rtc.networkMetrics.packetLossPercent, suffix: "%"))
                    Text(KikiL10n.text("指标来自本机 LiveKit 媒体统计；没有音频流或尚无报告时显示未采到，不代表零延迟或零丢包。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let incidentID = KikiIncidentReporter.shared.lastEventID {
                    Section(KikiL10n.text("最近的问题编号")) {
                        Text(incidentID).font(.footnote.monospaced()).textSelection(.enabled)
                        Text(KikiL10n.text("联系管理员时可提供此编号。网络恢复后会自动补交问题记录。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(KikiL10n.text("音频设备")) {
                    LabeledContent(KikiL10n.text("声音输出"), value: rtc.audioState.output)
                    LabeledContent(KikiL10n.text("声音输入"), value: rtc.audioState.input)
                    LabeledContent(KikiL10n.text("麦克风权限"), value: KikiMicrophonePermission.description)
                    LabeledContent(KikiL10n.text("本机麦克风"), value: rtc.microphoneEnabled ? KikiL10n.text("已开启") : KikiL10n.text("已关闭"))
                    Toggle(KikiL10n.text("内置设备优先使用扬声器"), isOn: Binding(get: { rtc.speakerPreferred }, set: rtc.setSpeakerPreferred))
                    HStack {
                        Text(KikiL10n.text("选择音频输出"))
                        Spacer()
                        KikiAudioRoutePicker().frame(width: 36, height: 36)
                    }
                    if let notice = rtc.audioState.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    Text(KikiL10n.text("耳机和蓝牙由系统选择。来电中断、设备断开或权限收回后，需手动开麦。锁屏和切后台可继续收听；系统仍可能限制网络及后台执行。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(KikiL10n.text("语聊服务 · 最近 5 分钟")) {
                    Button { Task { await rtc.loadServerDiagnostics() } } label: {
                        HStack { Text(KikiL10n.text("刷新服务器状态")); if rtc.isLoadingDiagnostics { Spacer(); ProgressView() } }
                    }.disabled(rtc.isLoadingDiagnostics)
                    if let value = rtc.serverDiagnostics {
                        LabeledContent(KikiL10n.text("活跃房间"), value: "\(count(value.capacity.activeRooms)) / \(count(value.capacity.maxRooms))")
                        LabeledContent(KikiL10n.text("实际在线"), value: count(value.capacity.activeParticipants))
                        LabeledContent(KikiL10n.text("已占入房名额"), value: "\(count(value.capacity.admittedParticipants)) / \(count(value.capacity.maxParticipantsTotal))")
                        LabeledContent(KikiL10n.text("单房人数上限"), value: count(value.capacity.maxParticipantsPerRoom))
                        LabeledContent(KikiL10n.text("信令接受 / 拒绝"), value: "\(value.connections.accepted) / \(value.connections.rejected)")
                        LabeledContent(KikiL10n.text("信令握手中位数"), value: metric(value.connections.handshakeMsP50, suffix: " ms"))
                        LabeledContent(KikiL10n.text("质量样本"), value: String(value.quality.samples))
                        LabeledContent(KikiL10n.text("较差 / 丢失样本"), value: "\(value.quality.poor) / \(value.quality.lost)")
                        LabeledContent(KikiL10n.text("样本延迟中位数"), value: metric(value.quality.rttMsP50, suffix: " ms"))
                        ForEach(value.alerts) { alert in Text(KikiL10n.text(alert.message)).font(.caption).foregroundStyle(.orange) }
                        Text(KikiL10n.text("容量为当前保护配置，不是压测容量。质量为登录房内客户端自报的去标识短期聚合。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = rtc.diagnosticsError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            .scrollContentBackground(.hidden).background(KikiPalette.background)
            .navigationTitle(KikiL10n.text("连接与音频")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(KikiL10n.text("完成")) { dismiss() } } }
        }.tint(KikiPalette.purple)
    }

    private func metric(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return KikiL10n.text("未采到") }
        return String(format: "%.1f", locale: KikiL10n.locale, value) + suffix
    }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? KikiL10n.text("未知") }
}
