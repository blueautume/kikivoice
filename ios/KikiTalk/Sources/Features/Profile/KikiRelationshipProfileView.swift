import SwiftUI

/// Two focused editors, available only from Me. Birth inputs and chart previews
/// stay in this owner-only page; all calendrical and chart work is server-side.
struct KikiRelationshipProfileView: View {
    @ObservedObject var store: KikiAppStore
    let editor: KikiRelationshipEditor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = KikiRelationshipProfileDraft()
    @State private var preview: KikiRelationshipProfile?
    @State private var placeName: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var saving = false
    @State private var calculating = false
    @State private var converting = false
    @State private var error: String?
    @State private var previewError: String?
    @State private var picker: PickerSheet?

    init(store: KikiAppStore, editor: KikiRelationshipEditor = .bazi) {
        self.store = store
        self.editor = editor
    }

    private enum PickerSheet: String, Identifiable {
        case date, time, place
        var id: String { rawValue }
    }
    private static let mbtiTypes = ["INTJ", "INTP", "ENTJ", "ENTP", "INFJ", "INFP", "ENFJ", "ENFP", "ISTJ", "ISFJ", "ESTJ", "ESFJ", "ISTP", "ISFP", "ESTP", "ESFP"]

    var body: some View {
        Form {
            if loading && !loaded {
                Section { HStack { Spacer(); ProgressView("正在读取资料…"); Spacer() }.padding(.vertical, 24) }
            }
            if loaded {
                if editor == .mbti {
                    mbtiSection
                } else {
                    birthSection
                    chartSection
                }
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(KikiPalette.warning)
                    if !loaded { Button("重新读取") { Task { await load() } } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(KikiPalette.background)
        .foregroundStyle(KikiPalette.text)
        .tint(KikiPalette.purple)
        .navigationTitle(editor.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView() } else { Text("保存").fontWeight(.semibold) }
                }
                .disabled(!loaded || saving || converting)
                .accessibilityIdentifier("relationshipProfile.save")
            }
        }
        .interactiveDismissDisabled(saving)
        .disabled(saving)
        .task { await load() }
        .task(id: draft) { await updatePreview() }
        .onChange(of: store.socialPrivacyRevision) { _, _ in clearAndDismiss() }
        .onChange(of: store.isAuthenticated) { _, authenticated in if !authenticated { clearAndDismiss() } }
        .onDisappear { if picker == nil { clearPrivateState() } }
        .sheet(item: $picker) { sheet in
            NavigationStack {
                switch sheet {
                case .date:
                    KikiRelationshipDatePicker(calendar: draft.birthCalendar, value: draft.birthDate,
                                               leapMonth: draft.birthLeapMonth) { date, leap in
                        draft.birthDate = date; draft.birthLeapMonth = leap; picker = nil
                    }
                case .time:
                    KikiRelationshipTimePicker(value: draft.birthTime) { value in
                        draft.birthTime = value; picker = nil
                    }
                case .place:
                    KikiRelationshipPlacePicker(store: store) { place in
                        draft.birthPlaceCode = place.id
                        placeName = place.fullName; picker = nil
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
    }

    private var mbtiSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 10) {
                ForEach(Self.mbtiTypes, id: \.self) { type in
                    Button { draft.mbtiType = type } label: {
                        Text(type)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(draft.mbtiType == type ? KikiPalette.purple : KikiPalette.text)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(draft.mbtiType == type ? KikiPalette.purple.opacity(0.14) : KikiPalette.elevated,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(draft.mbtiType == type ? KikiPalette.purple : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("relationshipProfile.mbti." + type)
                    .accessibilityAddTraits(draft.mbtiType == type ? .isSelected : [])
                }
            }
            .padding(.vertical, 8)
            Button("暂不清楚") { draft.mbtiType = nil }
                .foregroundStyle(KikiPalette.secondary)
                .accessibilityIdentifier("relationshipProfile.mbti.clear")
        } header: {
            Text("选择你的类型")
        } footer: {
            Text("MBTI 会展示在个人主页和房间，用于关系计算。")
        }
    }

    private var birthSection: some View {
        Section {
            editableRow("出生地", value: placeName, placeholder: "选择省、市、区县", identifier: "relationshipProfile.birthPlace") {
                picker = .place
            } clear: {
                draft.birthPlaceCode = nil; placeName = nil
            }
            Picker("历法", selection: Binding(get: { draft.birthCalendar }, set: { value in
                Task { await changeCalendar(to: value) }
            })) {
                ForEach(KikiBirthCalendar.allCases) { Text($0.title).tag($0) }
            }.disabled(converting)
            editableRow("出生日期", value: dateLabel, placeholder: "选择日期", identifier: "relationshipProfile.birthDate") {
                picker = .date
            } clear: {
                draft.birthDate = nil; draft.birthLeapMonth = false
            }
            editableRow("出生时刻", value: draft.birthTime, placeholder: "不清楚可留空", identifier: "relationshipProfile.birthTime") {
                picker = .time
            } clear: {
                draft.birthTime = nil
            }
            LabeledContent("星座", value: draft.birthDate == nil ? "完善生日后生成" : (preview?.zodiacSign ?? "正在计算…"))
                .accessibilityIdentifier("relationshipProfile.zodiac")
        } header: {
            Text("出生信息 · 仅本人可见")
        } footer: {
            Text("填写出生地的钟表时间。星座由生日自动生成并公开展示。")
        }
    }

    private var chartSection: some View {
        Section {
            if calculating || converting {
                HStack(spacing: 10) { ProgressView(); Text(converting ? "正在换算日期…" : "正在生成八字…") }
                    .foregroundStyle(KikiPalette.secondary)
            } else if let chart = preview?.chart {
                if let pillars = chart.pillars, !pillars.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 16) {
                        ForEach(Array(pillars.enumerated()), id: \.offset) { index, pillar in
                            VStack(spacing: 8) {
                                Text(["年柱", "月柱", "日柱", "时柱"][min(index, 3)])
                                    .font(.caption).foregroundStyle(KikiPalette.secondary)
                                Text(pillar).font(.title3.monospaced().weight(.medium))
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("relationshipProfile.privateChart")
                    if let time = chart.trueSolarTime {
                        LabeledContent("真太阳时", value: time).font(.footnote)
                    }
                } else {
                    Text(chart.message ?? "完善出生信息后自动生成。")
                        .font(.subheadline).foregroundStyle(KikiPalette.secondary)
                }
            } else {
                Text(previewError ?? "完善出生信息后自动生成。")
                    .font(.subheadline).foregroundStyle(KikiPalette.secondary)
            }
            if let previewError, preview?.chart != nil {
                Text(previewError).font(.caption).foregroundStyle(KikiPalette.warning)
            }
        } header: {
            Text("八字 · 仅本人可见")
        } footer: {
            Text("出生资料和八字仅自己可见，房间只展示计算结果。")
        }
    }

    private var dateLabel: String? {
        draft.birthDate.map { (draft.birthCalendar == .lunar && draft.birthLeapMonth ? "闰月 · " : "") + $0 }
    }

    private func editableRow(_ title: String, value: String?, placeholder: String, identifier: String,
                             action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack {
                    Text(title).foregroundStyle(KikiPalette.text)
                    Spacer(minLength: 12)
                    Text(value ?? placeholder).foregroundStyle(value == nil ? KikiPalette.muted : KikiPalette.secondary)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(KikiPalette.muted)
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            if value != nil {
                Button(action: clear) { Image(systemName: "xmark.circle.fill").foregroundStyle(KikiPalette.muted).frame(width: 32, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("清空\(title)").accessibilityIdentifier(identifier + ".clear")
            }
        }
    }

    private func load() async {
        guard !loading, !loaded else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let profile = try await store.loadRelationshipProfile()
            guard !Task.isCancelled else { return }
            draft = profile.draft; preview = profile
            placeName = profile.birthPlaceName; loaded = true
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func updatePreview() async {
        guard editor == .bazi, loaded, !saving, !converting else { return }
        let input = draft
        calculating = true; preview = nil; previewError = nil
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
            let result = try await store.previewRelationshipProfile(input)
            guard !Task.isCancelled, draft == input else { return }
            preview = result; calculating = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, draft == input else { return }
            previewError = error.localizedDescription; calculating = false
        }
    }

    private func changeCalendar(to calendar: KikiBirthCalendar) async {
        guard calendar != draft.birthCalendar, !converting else { return }
        guard draft.birthDate != nil else { draft.birthCalendar = calendar; draft.birthLeapMonth = false; return }
        let input = draft
        converting = true; error = nil
        defer { converting = false }
        do {
            let result = try await store.previewRelationshipProfile(input)
            guard !Task.isCancelled, input == draft else { return }
            guard let converted = input.changingCalendar(to: calendar, using: result) else {
                throw KikiAPIError.server(422, "这个日期暂无法换算，请核对出生记录。")
            }
            converting = false
            draft = converted
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        guard loaded, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            _ = try await store.saveRelationshipProfile(draft, editor: editor)
            store.notify(editor.title + "已保存")
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func clearAndDismiss() {
        clearPrivateState()
        dismiss()
    }

    private func clearPrivateState() {
        loaded = false; draft = .init(); preview = nil; placeName = nil
        calculating = false; converting = false; previewError = nil; error = nil
    }
}

private struct KikiRelationshipPlacePicker: View {
    @ObservedObject var store: KikiAppStore
    var parent: KikiRelationshipPlace? = nil
    let onSelect: (KikiRelationshipPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var places: [KikiRelationshipPlace] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if let parent, parent.hasCoordinates {
                Section {
                    Button { onSelect(parent) } label: { Label("使用\(parent.fullName)", systemImage: "checkmark.circle") }
                } footer: { Text("选择区县可提高计算精度。") }
            }
            Section {
                ForEach(places) { place in
                    if place.hasChildren {
                        NavigationLink(place.name) { KikiRelationshipPlacePicker(store: store, parent: place, onSelect: onSelect) }
                    } else {
                        Button { onSelect(place) } label: {
                            HStack { Text(place.name); Spacer(); if !place.hasCoordinates { Text("坐标待完善").font(.caption).foregroundStyle(KikiPalette.muted) } }
                        }.disabled(!place.hasCoordinates)
                    }
                }
                if loading { ProgressView("正在读取地区…") }
                if let error { Text(error).foregroundStyle(KikiPalette.warning); Button("重试") { Task { await load() } } }
            } header: {
                if parent == nil { Text("中国") }
            }
            if parent == nil {
                Section {
                    DisclosureGroup("地区数据来源") {
                        Text("行政区划：modood（WTFPL）；代表坐标及港澳台目录：GeoNames（CC BY 4.0）；补充坐标：Wikidata（CC0）。坐标为地区代表点。")
                            .font(.caption).foregroundStyle(KikiPalette.secondary)
                        Link("GeoNames 地理数据库", destination: URL(string: "https://www.geonames.org/")!)
                        Link("行政区划数据", destination: URL(string: "https://github.com/modood/Administrative-divisions-of-China")!)
                        Link("Wikidata 数据许可", destination: URL(string: "https://www.wikidata.org/wiki/Wikidata:Licensing")!)
                    }
                }
            }
        }
        .navigationTitle(parent?.name ?? "选择出生地")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if parent == nil { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } } }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { places = try await store.relationshipPlaces(parent: parent?.id) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct KikiRelationshipDatePicker: View {
    let calendar: KikiBirthCalendar
    let value: String?
    let leapMonth: Bool
    let onSelect: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var gregorian = KikiRelationshipClock.date("1995-01-01")
    @State private var year = 1995
    @State private var month = 1
    @State private var day = 1
    @State private var leap = false

    var body: some View {
        Form {
            if calendar == .gregorian {
                DatePicker("出生日期", selection: $gregorian,
                           in: KikiRelationshipClock.date("1900-01-01")...KikiRelationshipClock.date("2100-12-31"),
                           displayedComponents: .date)
                    .datePickerStyle(.wheel).labelsHidden()
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            } else {
                Picker("农历年", selection: $year) { ForEach(1900...2100, id: \.self) { Text(String($0)).tag($0) } }
                Picker("农历月", selection: $month) { ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) } }
                Picker("农历日", selection: $day) { ForEach(1...30, id: \.self) { Text("\($0)日").tag($0) } }
                Toggle("这是闰月", isOn: $leap)
                Text("请按出生记录选择闰月；日期和闰月由服务器核验并换算。")
                    .font(.footnote).foregroundStyle(KikiPalette.secondary)
            }
        }
        .navigationTitle("选择\(calendar.title)日期").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("确定") {
                    onSelect(calendar == .gregorian ? KikiRelationshipClock.string(gregorian, format: "yyyy-MM-dd") : String(format: "%04d-%02d-%02d", year, month, day), calendar == .lunar && leap)
                }
            }
        }
        .onAppear {
            if let value {
                gregorian = KikiRelationshipClock.date(value)
                let parts = value.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 { year = parts[0]; month = parts[1]; day = parts[2] }
            }
            leap = leapMonth
        }
    }
}

private struct KikiRelationshipTimePicker: View {
    let value: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = KikiRelationshipClock.date("2000-01-01 09:00", format: "yyyy-MM-dd HH:mm")
    var body: some View {
        Form {
            DatePicker("当地钟表时刻", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel).labelsHidden()
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            Text("填写记录中的当地钟表时间，无需自行换算真太阳时。不清楚时可以返回并留空。")
                .font(.footnote).foregroundStyle(KikiPalette.secondary)
        }
        .navigationTitle("出生时刻").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("确定") { onSelect(KikiRelationshipClock.string(time, format: "HH:mm")) } }
        }
        .onAppear { if let value { time = KikiRelationshipClock.date("2000-01-01 " + value, format: "yyyy-MM-dd HH:mm") } }
    }
}

/// Formats civil components for the controls; it never calculates a chart.
private enum KikiRelationshipClock {
    static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
    static func date(_ value: String, format: String = "yyyy-MM-dd") -> Date {
        formatter(format).date(from: value) ?? Date(timeIntervalSince1970: 0)
    }
    static func string(_ value: Date, format: String) -> String { formatter(format).string(from: value) }
}

struct KikiPublicRelationshipTags: View {
    let mbtiType: String?
    let zodiacSign: String?
    var body: some View {
        HStack(spacing: 8) {
            if let mbtiType { tag(mbtiType, symbol: "person.text.rectangle") }
            if let zodiacSign { tag(zodiacSign, symbol: "sparkles") }
        }
        .accessibilityElement(children: .combine)
    }
    private func tag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(KikiPalette.lavender).padding(.horizontal, 10).padding(.vertical, 6)
            .background(KikiPalette.purple.opacity(0.10), in: Capsule())
    }
}
