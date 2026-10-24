import SwiftUI
import PhotosUI
import ImageIO

@available(iOS 16.0, *)
struct KikiProfileView: View {
    var isActive = true
    @EnvironmentObject private var store: KikiAppStore
    @State private var activeSheet: KikiProfileSheet?
    @State private var pendingRoom: KikiRoom?
    @State private var relationship: KikiRelationshipKind?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    identity
                    library
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .kikiTransparentTopScrollEdge()
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { activeSheet = .settings } label: {
                        Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("打开设置")
                    .accessibilityIdentifier("profile.settings")
                }
            }
            .refreshable { await store.refreshLibrary(); await store.refreshSocialSummary() }
        }
        .sheet(item: $activeSheet, onDismiss: openPendingRoom) { sheet in
            sheetContent(sheet)
                .environmentObject(store)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $relationship) { KikiRelationshipsView(store: store, initialKind: $0) }
        .task(id: isActive) { if isActive { await store.refreshLibrary(); await store.refreshSocialSummary() } }
    }

    private var identity: some View {
        KikiProfileIdentityHeader {
            Button {
                activeSheet = .edit
            } label: {
                KikiAvatar(index: store.avatarIndex, size: 82, customURL: store.customAvatarURL)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 25, height: 25)
                            .background(KikiPalette.action, in: Circle())
                            .overlay(Circle().stroke(KikiPalette.background, lineWidth: 3))
                    }
            }
            .accessibilityLabel("编辑头像与个人资料")
        } details: {
            KikiProfileIdentityDetails(name: store.profileName, displayID: store.displayID,
                                       followingCount: store.socialProfile?.followingCount,
                                       followerCount: store.socialProfile?.followerCount) { relationship = $0 }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 13) {
            sectionTitle("我的社区")
            VStack(spacing: 0) {
                profileRow(symbol: "bookmark.fill", title: "我的收藏", count: store.favoriteRooms.count, color: KikiPalette.lavender) {
                    activeSheet = .favorites
                }
                rowDivider
                profileRow(symbol: "clock.arrow.circlepath", title: "最近加入", count: store.recentRooms.count, color: KikiPalette.mint) {
                    activeSheet = .history
                }

            }
            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 23))
        }
    }

    private var footer: some View {
        Text("Kiki 让世界听见你")
            .font(.footnote)
            .foregroundStyle(KikiPalette.muted)
            .frame(maxWidth: .infinity)
            .padding(.top, 1)
    }

    private var rowDivider: some View {
        Rectangle().fill(KikiPalette.elevated).frame(height: 1).padding(.leading, 66)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(KikiPalette.text)
    }

    private func profileRow(symbol: String, title: String, count: Int? = nil, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 37)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(KikiPalette.text)
                }
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(KikiPalette.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(KikiPalette.muted)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: KikiProfileSheet) -> some View {
        switch sheet {
        case .edit:
            KikiProfileEditor()
        case .favorites:
            KikiProfileRoomCollection(title: "我的收藏", subtitle: "喜欢的声音，随时再见。", collection: .favorites, emptySymbol: "bookmark", emptyTitle: "把喜欢的房间留在这里", emptyMessage: "长按大厅里的房间卡片即可收藏，下次就能快速找到。", onSelect: chooseRoom)
        case .history:
            KikiProfileRoomCollection(title: "最近加入", subtitle: "每一次相遇，都留下足迹。", collection: .history, emptySymbol: "clock", emptyTitle: "新的故事，等你开启", emptyMessage: "加入感兴趣的房间，你的足迹会出现在这里。", onSelect: chooseRoom)
        case .settings:
            KikiProfileSettings()
        }
    }

    private func chooseRoom(_ room: KikiRoom) {
        pendingRoom = room
        activeSheet = nil
    }

    private func openPendingRoom() {
        guard let room = pendingRoom else { return }
        pendingRoom = nil
        Task {
            do {
                try await store.openRoom(room)
            } catch {
                store.notify(error.localizedDescription)
            }
        }
    }
}

/// Larger accessibility text gets the full width instead of squeezing beside
/// the avatar. Normal text keeps the three rows level with the 82 pt avatar.
struct KikiProfileIdentityHeader<Avatar: View, Details: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var details: () -> Details

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 16) {
                avatar()
                details().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: 17) {
                avatar()
                details().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Three visible rows match the avatar height; the relationship buttons extend
/// their touch targets without adding empty height to the bottom row.
struct KikiProfileIdentityDetails: View {
    let name: String
    let displayID: String
    let followingCount: Int?
    let followerCount: Int?
    var onRelationship: (KikiRelationshipKind) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        KikiProfileIdentityRows(minimumSpacing: dynamicTypeSize.isAccessibilitySize ? 10 : 0) {
            nameRow
            accountRow
            relationshipsRow
        }
    }

    var nameRow: some View {
        KikiProfileIdentityName(name: name)
    }

    var accountRow: some View {
        KikiProfileIdentityAccount(displayID: displayID)
    }

    var relationshipsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { relationshipButtons }
            VStack(alignment: .leading, spacing: 12) { relationshipButtons }
        }
        .accessibilityIdentifier("profile.identity.relationships")
    }

    @ViewBuilder private var relationshipButtons: some View {
        relationshipButton(value: followingCount, title: "关注", kind: .following)
        relationshipButton(value: followerCount, title: "粉丝", kind: .followers)
    }

    private func relationshipButton(value: Int?, title: String, kind: KikiRelationshipKind) -> some View {
        let count = value.map(String.init) ?? "—"
        return HStack(spacing: 5) {
            Text(count).font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
            Text(title).font(.subheadline).foregroundStyle(KikiPalette.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityHidden(true)
        .overlay {
            Button { onRelationship(kind) } label: {
                Color.clear.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(count) \(title)")
            .accessibilityIdentifier("profile.relationship.\(kind.rawValue)")
        }
    }
}

private struct KikiProfileIdentityName: View {
    let name: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var accessibleSize: CGFloat = 26

    var body: some View {
        Text(name)
            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? accessibleSize : 26,
                          weight: .bold, design: .rounded))
            .foregroundStyle(KikiPalette.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.75)
            .accessibilityIdentifier("profile.identity.name")
    }
}

private struct KikiProfileIdentityAccount: View {
    let displayID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var accessibleSize: CGFloat = 13

    var body: some View {
        Text("账号 ID · \(displayID)")
            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? accessibleSize : 13,
                          weight: .medium, design: .monospaced))
            .foregroundStyle(KikiPalette.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .accessibilityIdentifier("profile.identity.account")
    }
}

/// Use each row's natural height, then divide all remaining vertical room into
/// two equal gaps. Accessible text may grow beyond the ordinary 82 pt minimum.
struct KikiProfileIdentityRows: Layout {
    var minimumSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let height = sizes.reduce(0) { $0 + $1.height } + minimumSpacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: width, height: max(82, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let rowHeight = sizes.reduce(0) { $0 + $1.height }
        let gap = subviews.count > 1 ? max(minimumSpacing, (bounds.height - rowHeight) / CGFloat(subviews.count - 1)) : 0
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: sizes[index].height))
            y += sizes[index].height + gap
        }
    }
}

private enum KikiProfileSheet: String, Identifiable {
    case edit, favorites, history, settings
    var id: String { rawValue }
}

@available(iOS 16.0, *)
private struct KikiProfileEditor: View {
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pendingJPEG: Data?
    @State private var photoPreview: UIImage?
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field { case name, bio }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(spacing: 12) {
                        Group {
                            if let photoPreview {
                                Image(uiImage: photoPreview).resizable().scaledToFill()
                                    .frame(width: 98, height: 98).clipShape(Circle())
                            } else {
                                KikiAvatar(index: store.avatarIndex, size: 98, customURL: store.customAvatarURL)
                            }
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                            HStack(spacing: 7) {
                                if isLoadingPhoto { ProgressView().tint(KikiPalette.lavender) }
                                else { Image(systemName: "photo.on.rectangle") }
                                Text(isLoadingPhoto ? "正在处理照片…" : "从相册选择头像")
                            }.font(.system(size: 13, weight: .semibold)).foregroundStyle(KikiPalette.lavender)
                                .padding(.horizontal, 16).padding(.vertical, 11)
                                .background(KikiPalette.purple.opacity(0.12), in: Capsule())
                        }
                        .disabled(isLoadingPhoto || isSaving)
                        .accessibilityIdentifier("chooseAvatarPhoto")
                        Text(pendingJPEG == nil ? "上传照片作为你的头像" : "照片将在保存资料后上传")
                            .font(.system(size: 12))
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 10) {
                        fieldHeading("昵称", count: name.count, limit: 16)
                        TextField("大家该怎么称呼你？", text: $name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .bio }
                            .onChange(of: name) { value in
                                if value.count > 16 { name = String(value.prefix(16)) }
                            }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        fieldHeading("关于我", count: bio.count, limit: 80)
                        TextField("说说你的兴趣，或想聊的话题…", text: $bio, axis: .vertical)
                            .font(.system(size: 14))
                            .lineSpacing(5)
                            .lineLimit(3...5)
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                            .focused($focusedField, equals: .bio)
                            .onChange(of: bio) { value in
                                if value.count > 80 { bio = String(value.prefix(80)) }
                            }
                    }

                    Label("资料保存后会同步到你的账号。", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(KikiPalette.muted)
                    Text("保存后的昵称、头像和简介会在大厅、房间、麦位、成员列表及聊天名片等场景向其他用户展示。头像只上传你选择并确认保存的照片。")
                        .font(.system(size: 11)).lineSpacing(5).foregroundStyle(KikiPalette.secondary)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                }
                .padding(24)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .disabled(isSaving)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("编辑资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.secondary)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if isSaving { ProgressView().tint(KikiPalette.lavender) }
                        else { Text("保存").fontWeight(.semibold) }
                    }
                    .foregroundStyle(trimmedName.isEmpty ? KikiPalette.muted : KikiPalette.lavender)
                    .disabled(trimmedName.isEmpty || isSaving || isLoadingPhoto)
                    .accessibilityIdentifier("saveProfile")
                }
            }
            .task(id: selectedPhoto) { await loadSelectedPhoto() }
            .onAppear {
                name = store.profileName
                bio = store.bio
            }
        }
        .tint(KikiPalette.lavender)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !trimmedName.isEmpty, !isSaving, !isLoadingPhoto else { return }
        focusedField = nil
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.updateProfile(name: trimmedName, bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), jpegData: pendingJPEG)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadSelectedPhoto() async {
        guard let selection = selectedPhoto else { isLoadingPhoto = false; return }
        isLoadingPhoto = true
        errorMessage = nil
        defer { if selectedPhoto == selection { isLoadingPhoto = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw KikiAPIError.server(422, "无法读取这张照片，请重新选择。")
            }
            try Task.checkCancellation()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try KikiAvatarPhoto.prepare(data)
            }.value
            try Task.checkCancellation()
            guard selectedPhoto == selection else { return }
            pendingJPEG = prepared.data
            photoPreview = prepared.image
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, selectedPhoto == selection else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fieldHeading(_ title: String, count: Int, limit: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(KikiPalette.secondary)
            Spacer()
            Text("\(count)/\(limit)").foregroundStyle(KikiPalette.muted)
        }
        .font(.system(size: 12, weight: .medium))
    }
}

private enum KikiRoomCollectionKind {
    case favorites, history
}

/// Downsample before decoding the full photo, correct EXIF orientation, and
/// center-crop a square JPEG. A chosen image stays local until Save is tapped.
private enum KikiAvatarPhoto {
    static func prepare(_ data: Data) throws -> (data: Data, image: UIImage) {
        guard data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw KikiAPIError.server(422, "照片无法读取或超过 30 MB，请换一张照片。")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw KikiAPIError.server(422, "这张照片无法处理，请选择其他图片。")
        }
        let side = min(thumbnail.width, thumbnail.height)
        guard side > 0, let cropped = thumbnail.cropping(to: CGRect(x: CGFloat((thumbnail.width - side) / 2),
                                                                 y: CGFloat((thumbnail.height - side) / 2),
                                                                 width: CGFloat(side), height: CGFloat(side))) else {
            throw KikiAPIError.server(422, "头像裁剪失败，请重新选择。")
        }
        let image = UIImage(cgImage: cropped)
        for quality in [0.88, 0.72, 0.55] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 2 * 1024 * 1024 {
                return (jpeg, image)
            }
        }
        throw KikiAPIError.server(422, "照片压缩后仍然过大，请换一张照片。")
    }
}

@available(iOS 16.0, *)
private struct KikiProfileRoomCollection: View {
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    let collection: KikiRoomCollectionKind
    let emptySymbol: String
    let emptyTitle: String
    let emptyMessage: String
    let onSelect: (KikiRoom) -> Void
    @State private var selectedRecord: KikiRoom?
    @State private var confirmsClear = false
    @State private var isChanging = false
    @State private var error: String?

    private var rooms: [KikiRoom] {
        switch collection {
        case .favorites: return store.favoriteRooms
        case .history: return store.recentRooms
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(KikiPalette.secondary)
                        Spacer()
                        Text("\(rooms.count) 个房间")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(KikiPalette.muted)
                    }
                    .padding(.vertical, 8)

                    if let error = error ?? store.libraryError {
                        KikiInlineError(message: error) { Task { await store.refreshLibrary() } }
                    }
                    if rooms.isEmpty && store.libraryError == nil {
                        VStack(spacing: 18) {
                            Image(systemName: emptySymbol)
                                .font(.system(size: 35, weight: .light))
                                .foregroundStyle(KikiPalette.lavender)
                                .frame(width: 88, height: 88)
                                .background(KikiPalette.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 30))
                            Text(emptyTitle)
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(KikiPalette.text)
                            Text(emptyMessage)
                                .font(.system(size: 13))
                                .lineSpacing(6)
                                .foregroundStyle(KikiPalette.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 270)
                            Button("返回我的空间") { dismiss() }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KikiPalette.lavender)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(KikiPalette.purple.opacity(0.15), in: Capsule())
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 90)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(rooms) { room in
                                Button {
                                    if room.status == "live" { onSelect(room) }
                                    else { selectedRecord = room }
                                } label: {
                                    KikiRoomCard(room: room)
                                        .overlay(alignment: .topTrailing) {
                                            if room.status != "live" {
                                                Text(room.status == "draft" ? "未开播" : "已结束")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(KikiPalette.secondary)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(KikiPalette.background.opacity(0.9), in: Capsule())
                                                    .padding(12)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    if store.favoriteIDs.contains(room.id) || room.status == "live" {
                                        Button { store.toggleFavorite(room) } label: {
                                            Label(store.favoriteIDs.contains(room.id) ? "取消收藏" : "收藏房间", systemImage: store.favoriteIDs.contains(room.id) ? "bookmark.slash" : "bookmark")
                                        }
                                    }
                                    if collection == .history {
                                        Button("移除这条足迹", role: .destructive) { Task { await removeHistory(room.id) } }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .padding(.bottom, 25)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .refreshable { await store.refreshLibrary() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedRecord) { KikiRoomRecordView(room: $0, store: store) }
            .confirmationDialog("清空最近加入记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
                Button("清空记录", role: .destructive) { Task { await removeHistory(nil) } }
                Button("取消", role: .cancel) { }
            }
            .toolbar {
                if collection == .history, !rooms.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { Button("清空") { confirmsClear = true }.disabled(isChanging) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                }
            }
        }
    }

    private func removeHistory(_ roomID: String?) async {
        guard !isChanging else { return }; isChanging = true; defer { isChanging = false }
        do { try await store.removeHistory(roomID: roomID); error = nil }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
struct KikiProfileSettings: View {
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [KikiSettingsDestination] = []
    @State private var presented: KikiSettingsDestination?
    @State private var isLoggingOut = false

    var body: some View {
        NavigationStack(path: $path) {
            KikiSettingsMenuContent { destination in
                switch destination {
                case .account, .privacy, .help: path.append(destination)
                case .notifications, .about: presented = destination
                case .rating: break
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: KikiSettingsDestination.self) { destination in
                switch destination {
                case .account:
                    KikiAccountSettings(isLoggingOut: $isLoggingOut) { dismiss() }
                case .privacy:
                    KikiSettingsPrivacy()
                case .help:
                    KikiPrivacyHelp()
                case .notifications, .rating, .about:
                    EmptyView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                        .disabled(isLoggingOut)
                }
            }
            .sheet(item: $presented) { destination in
                switch destination {
                case .notifications:
                    KikiPushPreferencesView(store: store, push: store.pushController ?? .shared)
                case .about:
                    KikiProfileAbout()
                default:
                    EmptyView()
                }
            }
        }
        .tint(KikiPalette.purple)
        .interactiveDismissDisabled(isLoggingOut)
    }
}

@available(iOS 16.0, *)
private struct KikiAccountSettings: View {
    @EnvironmentObject private var store: KikiAppStore
    @Binding var isLoggingOut: Bool
    let onSessionEnded: () -> Void
    @State private var showLogoutConfirmation = false
    @State private var showDeletion = false

    var body: some View {
        KikiAccountSettingsContent(userID: store.displayID, appleIDBound: store.isAppleIDBound,
                                   isLoggingOut: isLoggingOut,
                                   onLogout: { showLogoutConfirmation = true },
                                   onDelete: { showDeletion = true })
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isLoggingOut)
            .confirmationDialog("退出当前账号？", isPresented: $showLogoutConfirmation, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    guard !isLoggingOut else { return }
                    isLoggingOut = true
                    Task {
                        await store.logout()
                        isLoggingOut = false
                        onSessionEnded()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("资料和房间记录会保留，再次登录后可继续使用。")
            }
            .sheet(isPresented: $showDeletion) {
                KikiAccountDeletion {
                    showDeletion = false
                    onSessionEnded()
                }
                .environmentObject(store)
            }
    }
}

@available(iOS 16.0, *)
private struct KikiSettingsPrivacy: View {
    @State private var showsLegal = false
    @State private var showsSafety = false

    var body: some View {
        List {
            Section {
                Button { showsLegal = true } label: {
                    Label("隐私政策与权限", systemImage: "hand.raised.fill")
                }
                .accessibilityIdentifier("settings.privacyCenter")
                Button { showsSafety = true } label: {
                    Label("社区安全、黑名单与我的举报", systemImage: "checkmark.shield.fill")
                }
                .accessibilityIdentifier("settings.communitySafety")
            }
        }
        .navigationTitle("隐私中心")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsLegal) { KikiPrivacyCenter() }
        .sheet(isPresented: $showsSafety) { KikiSafetyCenter(rtc: .shared) }
    }
}

@available(iOS 16.0, *)
private struct KikiAccountDeletion: View {
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    let onDeleted: () -> Void
    @State private var confirmationID = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var copiedNoticeID: UUID?
    private var canDelete: Bool { !store.displayID.isEmpty && confirmationID == store.displayID && !isDeleting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "person.crop.circle.badge.minus")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.red.opacity(0.85))
                        .padding(.top, 20)
                    Text("确认注销账号")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(KikiPalette.text)
                    Text("此操作会永久删除个人资料、收藏和加入记录，并结束你创建的活动房间。删除后不可恢复。")
                        .font(.system(size: 14))
                        .lineSpacing(7)
                        .foregroundStyle(KikiPalette.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("请输入当前账号 ID：")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(KikiPalette.secondary)
                        HStack(spacing: 8) {
                            Text(store.displayID)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundStyle(KikiPalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                UIPasteboard.general.string = store.displayID
                                copiedNoticeID = UUID()
                                UIAccessibility.post(notification: .announcement, argument: "已复制ID")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 15)).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain).foregroundStyle(KikiPalette.purple)
                            .disabled(store.displayID.isEmpty)
                            .accessibilityLabel("复制账号 ID")
                            .accessibilityIdentifier("deleteAccountCopyID")
                        }
                        TextField("账号 ID", text: $confirmationID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(KikiPalette.text)
                            .padding(17)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                            .disabled(isDeleting)
                            .accessibilityIdentifier("deleteAccountConfirmationID")
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                    Button(action: deleteAccount) {
                        HStack(spacing: 10) {
                            if isDeleting { ProgressView().tint(.white) }
                            Text(isDeleting ? "正在注销…" : "永久注销账号")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canDelete || isDeleting ? .white : KikiPalette.muted)
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .background(canDelete || isDeleting ? Color.red.opacity(0.8) : KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(!canDelete)
                    .accessibilityIdentifier("confirmDeleteAccount")
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("注销账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                        .disabled(isDeleting)
                }
            }
            .overlay(alignment: .top) {
                if copiedNoticeID != nil {
                    Text("已复制ID").font(.subheadline.weight(.medium))
                        .foregroundStyle(KikiPalette.text)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8).allowsHitTesting(false)
                        .accessibilityIdentifier("deleteAccountCopiedNotice")
                }
            }
            .task(id: copiedNoticeID) {
                guard let noticeID = copiedNoticeID else { return }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                if copiedNoticeID == noticeID { copiedNoticeID = nil }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func deleteAccount() {
        guard canDelete else { return }
        errorMessage = nil
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await store.deleteAccount()
                onDeleted()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@available(iOS 16.0, *)
private struct KikiProfileAbout: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 27) {
                    VStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 28)
                                .fill(LinearGradient(colors: [KikiPalette.lavender, KikiPalette.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 96, height: 96)
                            Image(systemName: "waveform")
                                .font(.system(size: 42, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        Text("Kiki")
                            .font(.system(size: 29, weight: .bold, design: .rounded))
                            .foregroundStyle(KikiPalette.text)
                        Text("让世界听见你")
                            .font(.system(size: 14))
                            .tracking(3)
                            .foregroundStyle(KikiPalette.secondary)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(KikiPalette.lavender)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(KikiPalette.purple.opacity(0.12), in: Capsule())
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 10)

                    VStack(alignment: .leading, spacing: 18) {
                        aboutItem("bubble.left.and.bubble.right", title: "从一句你好开始", message: "发现语聊房间，用声音结识有趣的人，找到属于你的同频社区。")
                        Rectangle().fill(KikiPalette.elevated).frame(height: 1)
                        aboutItem("waveform", title: "让声音跨越距离", message: "开启语聊房，邀请朋友加入，一起分享声音和此刻。")
                        Rectangle().fill(KikiPalette.elevated).frame(height: 1)
                        aboutItem("person.crop.circle.badge.checkmark", title: "你的社区，随时相见", message: "个人资料、收藏与加入记录跟随账号保存。使用同一个 Apple 账户重新登录后可继续访问。")
                    }
                    .padding(22)
                    .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 25))

                    Text("一段对话，一个新的可能。")
                        .font(.system(size: 11))
                        .foregroundStyle(KikiPalette.muted)
                        .padding(.bottom, 25)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("关于 Kiki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(KikiPalette.lavender)
                }
            }
        }
    }

    private func aboutItem(_ symbol: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(KikiPalette.lavender)
                .frame(width: 25)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KikiPalette.text)
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(6)
                    .foregroundStyle(KikiPalette.secondary)
            }
        }
    }
}

/// The same authenticated voice identity owns reports and blocks on every device.
struct KikiSafetyCenter: View {
    @ObservedObject var rtc: KikiRTCService
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var unblockTarget: KikiBlockedUser?

    var body: some View {
        NavigationStack {
            List {
                if rtc.isLoadingSafety { ProgressView("正在同步社区安全信息") }
                if let message = error ?? rtc.safetyError {
                    Section {
                        Text(message).foregroundStyle(.orange)
                        Button("重试同步") { Task { await reload() } }
                    }
                }
                Section("账号当前状态") {
                    restriction("语聊服务封禁", until: rtc.safetyState.restrictions.bannedUntil)
                    restriction("文字禁言", until: rtc.safetyState.restrictions.chatMutedUntil)
                    restriction("语音禁麦", until: rtc.safetyState.restrictions.voiceMutedUntil)
                    if !rtc.safetyState.restrictions.isActive(rtc.safetyState.restrictions.bannedUntil),
                       !rtc.safetyState.restrictions.isActive(rtc.safetyState.restrictions.chatMutedUntil),
                       !rtc.safetyState.restrictions.isActive(rtc.safetyState.restrictions.voiceMutedUntil) {
                        Text("当前未查询到社区限制").foregroundStyle(.secondary)
                    }
                    Text("房间管理者设置的本房禁言、禁麦和禁入，另在房间内显示。").font(.caption).foregroundStyle(.secondary)
                }
                Section("运营通知") {
                    if rtc.safetyState.notices.isEmpty { Text("暂无运营通知").foregroundStyle(.secondary) }
                    ForEach(rtc.safetyState.notices) { notice in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(notice.message)
                            Text(Date(timeIntervalSince1970: notice.createdAt), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if rtc.safetyState.blockedUsers.isEmpty { Text("暂无拉黑用户").foregroundStyle(.secondary) }
                    ForEach(rtc.safetyState.blockedUsers) { user in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(user.name)
                                Text(user.publicID).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("解除") { unblockTarget = user }.buttonStyle(.borderless).disabled(rtc.isUpdatingBlock)
                                .accessibilityLabel("解除对\(user.name)的拉黑")
                                .accessibilityIdentifier("settings.unblock.\(user.userID)")
                        }
                    }
                } header: { Text("黑名单 · \(rtc.safetyState.blockedUsers.count)") }
                footer: { Text("拉黑后隐藏对方私信和房间文字，并屏蔽对方音频。解除后可再次接收对方内容，关注关系不会自动恢复；公开房间内，对方仍可能听到你。") }
                Section {
                    if rtc.myReports.isEmpty { Text("暂无举报记录").foregroundStyle(.secondary) }
                    ForEach(rtc.myReports) { report in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(report.reason.label); Spacer(); Text(report.statusLabel).foregroundStyle(.secondary) }
                            Text("举报编号 \(report.id)").font(.caption2).textSelection(.enabled)
                            Text("房间 \(report.roomID)").font(.caption2).foregroundStyle(.secondary)
                            if !report.details.isEmpty { Text(report.details).font(.caption) }
                            Text(Date(timeIntervalSince1970: report.createdAt), style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("我的举报") }
                footer: { Text("显示最近 \(rtc.reportRetentionDays) 天的可用记录。举报提交成功不表示已认定违规；运营核查后更新状态。") }
                Section("帮助与申诉") {
                    Link("联系运营：2114581274@qq.com", destination: URL(string: "mailto:2114581274@qq.com?subject=Kiki%E7%A4%BE%E5%8C%BA%E5%8F%8D%E9%A6%88")!)
                    Text("申诉时请提供账号编号、举报编号或房间编号和发生时间。请勿发送 Apple 密码、登录凭证或完整身份证照片。当前不承诺全天人工值守。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("社区安全与通知").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await reload() }
            .refreshable { await reload() }
            .confirmationDialog("解除对 \(unblockTarget?.name ?? "此用户") 的拉黑？", isPresented: Binding(get: { unblockTarget != nil }, set: { if !$0 { unblockTarget = nil } }), titleVisibility: .visible) {
                Button("解除拉黑") {
                    guard let userID = unblockTarget?.userID else { return }
                    unblockTarget = nil
                    Task { do { try await rtc.setBlocked(userID, enabled: false) } catch { self.error = error.localizedDescription } }
                }
                Button("取消", role: .cancel) { unblockTarget = nil }
            }
        }
    }

    @ViewBuilder private func restriction(_ title: String, until: Double?) -> some View {
        if rtc.safetyState.restrictions.isActive(until), let until {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.orange)
                Text("截止 \(Date(timeIntervalSince1970: until).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() async {
        error = nil
        do { try await rtc.refreshSafety(includeReports: true) }
        catch { self.error = error.localizedDescription }
    }
}

struct KikiSafetyReportForm: View {
    @ObservedObject var rtc: KikiRTCService
    let target: KikiReportTarget
    @Environment(\.dismiss) private var dismiss
    @State private var reason = KikiReportReason.harassment
    @State private var details = ""
    @State private var request: KikiSafetyReportRequest?
    @State private var isSubmitting = false
    @State private var submitted: KikiSafetyReport?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let submitted {
                    Section("举报已提交") {
                        Label("等待运营核查", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("举报编号 \(submitted.id)").textSelection(.enabled)
                        Text("可在“设置 > 隐私 > 社区安全、黑名单与我的举报”查看处理状态。").font(.footnote)
                    }
                } else {
                    Section("举报对象") {
                        Text(target.name)
                        Text("房间 \(target.roomID)").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("违规原因") {
                        Picker("原因", selection: $reason) { ForEach(KikiReportReason.allCases) { Text($0.label).tag($0) } }.pickerStyle(.inline).labelsHidden()
                    }.disabled(request != nil)
                    Section {
                        TextEditor(text: $details).frame(minHeight: 120).disabled(request != nil)
                        Text("\(details.unicodeScalars.count)/500 字").font(.caption).foregroundStyle(details.unicodeScalars.count > 500 ? .red : .secondary)
                    } header: { Text("补充说明（可选）") }
                    footer: { Text("请说明发生时间和具体情况，不要填写密码或不必要的敏感信息。举报只向获授权的运营人员提供，不会公开到房间。") }
                    if let error {
                        Section {
                            Text(error).foregroundStyle(.orange)
                            Text("重试会继续提交相同内容，避免重复举报。如需修改，请关闭后重新填写。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { Task { await submit() } } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() }; Text(request == nil ? "提交举报" : "重试提交"); Spacer() }
                    }.disabled(isSubmitting || details.unicodeScalars.count > 500)
                }
            }
            .navigationTitle("举报").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(submitted == nil ? "取消" : "完成") { dismiss() }.disabled(isSubmitting) }
                ToolbarItem(placement: .confirmationAction) {
                    if submitted == nil {
                        Button(isSubmitting ? "提交中…" : (request == nil ? "提交" : "重试")) { Task { await submit() } }
                            .disabled(isSubmitting || details.unicodeScalars.count > 500)
                    }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        let value = request ?? KikiSafetyReportRequest(clientRequestID: UUID().uuidString.lowercased(), targetType: target.targetType,
                                                       roomID: target.roomID, targetUserID: target.targetUserID, messageID: target.messageID,
                                                       reason: reason, details: details.trimmingCharacters(in: .whitespacesAndNewlines))
        request = value
        do { submitted = try await rtc.submitReport(value) }
        catch { self.error = error.localizedDescription }
    }
}

private struct KikiPrivacyHelp: View {
    var body: some View {
        List {
            Section("设备权限") {
                Text("麦克风仅在你主动开麦时申请；拒绝后仍可聆听和发送文字。头像使用系统照片选择器，只访问你选中的照片。当前不申请定位、通讯录、相机或广告跟踪权限。")
                Link("打开 Kiki 系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
            Section("通知与后台语聊") {
                Text("系统通知需你主动允许，可在“设置 > 通知”开启或关闭。提醒预览不显示对方姓名和消息正文。最小化房间仍可能保持收听和发言；需要停止时，请关闭麦克风或离开房间。")
            }
            Section("隐私与使用统计") {
                Text("用于统计日活与回访的账号活跃记录按天保存，最长保留 35 天，注销或撤回同意时删除。社区举报的必要证据和处理记录按隐私政策保存；拉黑记录随账号同步。")
                Text("账号、隐私政策、撤回同意和注销入口仍可使用。公开房间内请谨慎分享个人信息。")
            }
            Section("帮助与反馈") {
                Link("发送反馈邮件", destination: URL(string: "mailto:2114581274@qq.com?subject=Kiki%E5%8F%8D%E9%A6%88")!)
                Text("联系邮箱：2114581274@qq.com").textSelection(.enabled)
                Text("请附账号或房间编号、问题时间、设备与系统版本；不要提供密码或登录凭证。如设备未配置邮件应用，可复制邮箱到自己的邮件工具发送。")
            }
        }.navigationTitle("帮助与反馈").navigationBarTitleDisplayMode(.inline)
    }
}
