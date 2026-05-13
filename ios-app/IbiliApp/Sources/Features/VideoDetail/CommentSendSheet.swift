import SwiftUI
import UIKit

/// Bottom sheet for posting a top-level comment under a video.
///
/// Matches the look-and-feel of `DanmakuSendSheet`: the same compact
/// composer card, with a footer row that swaps the danmaku-only
/// 颜色/模式 button for two attachment toggles — 表情 and 图片. The
/// emote panel and image strip slide in / out below the input. We
/// never set `sync_to_dynamic` so comments cannot leak to the
/// user's dynamic feed.
struct CommentSendSheet: View {
    let oid: Int64
    let kind: Int32
    /// Display info for the local-echo reply we synthesize after a
    /// successful submit (the host then prepends it to the comment
    /// list to avoid a full refetch).
    let selfMid: Int64
    let selfName: String
    var root: Int64 = 0
    var parent: Int64 = 0
    var replyToName: String?

    var onSent: ((ReplyItemDTO) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var images: [UIImage] = []
    @State private var showPhotoPicker = false
    @State private var showEmotePanel = false
    @State private var emotePackages: [EmotePackageDTO] = []
    @State private var emotesLoading = false
    @FocusState private var focused: Bool

    private let charLimit = 1000
    private let maxImages = 9

    private var placeholderText: String {
        if let replyToName, !replyToName.isEmpty {
            return "回复 @\(replyToName)…"
        }
        return "发条友善的评论…"
    }

    var body: some View {
        VStack(spacing: 12) {
            CompactComposerCard(
                text: $text,
                placeholder: placeholderText,
                charLimit: charLimit,
                isSending: isSending,
                focused: $focused,
                onSend: { Task { await send() } },
                trailing: {
                    HStack(spacing: 8) {
                        attachmentButton(
                            symbol: "face.smiling",
                            label: "表情",
                            active: showEmotePanel
                        ) {
                            showEmotePanel.toggle()
                            if showEmotePanel {
                                focused = false
                                if emotePackages.isEmpty { Task { await loadEmotes() } }
                            } else {
                                focused = true
                            }
                        }
                        attachmentButton(
                            symbol: "photo",
                            label: "图片",
                            active: !images.isEmpty
                        ) {
                            showPhotoPicker = true
                        }
                    }
                }
            )

            if !images.isEmpty {
                imageStrip
            }

            if showEmotePanel {
                emotePanel
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity
                        )
                    )
            }

            if let err = errorText {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .top)
        .presentationDetents(presentationDetents)
        .presentationDragIndicator(.visible)
        .modifier(MaterialSheetBg())
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showEmotePanel)
        .animation(.easeOut(duration: 0.18), value: images.count)
        .sheet(isPresented: $showPhotoPicker) {
            PrivatePhotoPicker(selectionLimit: maxImages - images.count) { picked in
                images.append(contentsOf: picked)
            }
            .ignoresSafeArea()
        }
    }

    private var presentationDetents: Set<PresentationDetent> {
        if showEmotePanel { return [.height(420)] }
        if !images.isEmpty { return [.height(280)] }
        return [.height(180)]
    }

    @ViewBuilder
    private func attachmentButton(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).imageScale(.small)
                Text(label).font(.caption.weight(.medium))
            }
            .foregroundStyle(active ? IbiliTheme.accent : IbiliTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(active ? IbiliTheme.accent.opacity(0.12) : Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Image strip

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            images.remove(at: idx)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.medium)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Emote panel

    private var emotePanel: some View {
        Group {
            if emotesLoading && emotePackages.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .frame(height: 180)
            } else if emotePackages.isEmpty {
                Text("暂无表情包")
                    .font(.footnote)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                EmotePanelGrid(packages: emotePackages) { emote in
                    text.append(emote.text)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    // MARK: - Submit

    private func loadEmotes() async {
        emotesLoading = true
        defer { emotesLoading = false }
        do {
            let pkgs = try await Task.detached(priority: .userInitiated) {
                try CoreClient.shared.emotePanel(business: "reply")
            }.value
            emotePackages = pkgs
        } catch {
            // Silent — user can still post text only.
            AppLog.error("comments", "表情面板加载失败", error: error)
        }
    }

    private func send() async {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty || !images.isEmpty else { return }
        guard text.count <= charLimit else { return }
        isSending = true
        errorText = nil
        defer { isSending = false }
        do {
            // Upload images sequentially so order is preserved and we
            // can surface the first failure verbatim. Most users post
            // 0–2 images so the lack of parallelism is fine.
            var pictures: [ReplyPictureDTO] = []
            for image in images {
                guard let data = image.jpegData(compressionQuality: 0.85) else { continue }
                let uploaded = try await Task.detached(priority: .userInitiated) {
                    try CoreClient.shared.uploadBfs(bytes: data, fileName: "comment.jpg")
                }.value
                pictures.append(ReplyPictureDTO(
                    imgSrc: uploaded.url,
                    imgWidth: uploaded.width,
                    imgHeight: uploaded.height,
                    imgSize: uploaded.size
                ))
            }
            let outgoingMessage: String
            if root != 0, parent != 0, parent != root, let replyToName, !replyToName.isEmpty {
                outgoingMessage = "回复 @\(replyToName) : \(msg)"
            } else {
                outgoingMessage = msg
            }
            let result = try await Task.detached(priority: .userInitiated) { [oid, kind, root, parent, outgoingMessage, pictures] in
                try CoreClient.shared.replyAdd(
                    oid: oid, kind: kind,
                    message: outgoingMessage, root: root, parent: parent,
                    pictures: pictures
                )
            }.value
            // Synthesize a local-echo so the host can prepend it to
            // the comment list without a refetch round-trip.
            let echo = ReplyItemDTO(
                rpid: result.rpid != 0 ? result.rpid : -Int64(Date().timeIntervalSince1970 * 1000),
                oid: oid,
                root: root,
                parent: parent,
                mid: selfMid,
                uname: selfName.isEmpty ? "我" : selfName,
                face: "",
                message: outgoingMessage,
                ctime: Int64(Date().timeIntervalSince1970),
                pictures: pictures.map { $0.imgSrc }
            )
            onSent?(echo)
            dismiss()
        } catch {
            errorText = (error as NSError).localizedDescription
        }
    }
}

/// Grid view that paginates the user's emote packages into
/// horizontally-paged tabs. Tapping any emote calls `onPick` with the
/// emote's `text` token (e.g. `[doge]`) — Bilibili's reply pipeline
/// converts those server-side into the rich-text representation.
private struct EmotePanelGrid: View {
    let packages: [EmotePackageDTO]
    let onPick: (EmoteDTO) -> Void

    @State private var selected: Int = 0

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 7
    )

    var body: some View {
        VStack(spacing: 0) {
            if let pkg = packages[safe: selected] {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(pkg.emotes) { e in
                            Button {
                                onPick(e)
                            } label: {
                                RemoteImage(
                                    url: e.url,
                                    contentMode: .fit,
                                    targetPointSize: CGSize(width: 80, height: 80),
                                    quality: 80
                                )
                                .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 180)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(packages.enumerated()), id: \.offset) { idx, pkg in
                        Button {
                            selected = idx
                        } label: {
                            RemoteImage(
                                url: pkg.url,
                                contentMode: .fit,
                                targetPointSize: CGSize(width: 60, height: 60),
                                quality: 80
                            )
                            .frame(width: 28, height: 28)
                            .padding(4)
                            .background(
                                Capsule().fill(idx == selected ? IbiliTheme.accent.opacity(0.18) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

/// Apply `.presentationBackground(.regularMaterial)` only on the OS
/// versions that support it (iOS 16.4+) — older targets fall back
/// to the system default sheet background.
private struct MaterialSheetBg: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground(.regularMaterial)
        } else {
            content
        }
    }
}
