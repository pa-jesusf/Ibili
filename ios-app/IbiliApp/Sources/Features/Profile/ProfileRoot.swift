import SwiftUI

/// 我的 (Profile) — redesigned root.
///
/// Layout (top → bottom):
///   1. Profile header card: avatar, name, sign, fans/following pill row.
///      Tap fans / following → push the `RelationListView` for that scope.
///   2. Quick-action grid (2×2): 历史 / 收藏 / 追番 / 稍后再看. We mirror
///      upstream PiliPlus's "我的" surface but render as a grid of large
///      iconic cards rather than a list of system rows — closer in feel
///      to Apple's own Music / TV "Library" hubs.
///   3. Settings & logs list.
///
/// Aesthetic notes (per the user's standing brief):
///   • No decorative gradients beyond the avatar ring; surfaces are
///     `IbiliTheme.surface` for the SF-symbol cards so they read as
///     pressable affordances rather than badges.
///   • Counts use `.contentTransition(.numericText())` so the header
///     animates smoothly as the card hydrates, instead of popping.
struct ProfileRoot: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var loader = ProfileHeaderLoader()
    @State private var headerCollapseProgress: CGFloat = 0

    var body: some View {
        ScrollView {
            if #unavailable(iOS 18.0) {
                ScrollHeaderOffsetReader(coordinateSpace: "profile-scroll")
            }

            FeedTitleHeader(
                title: "我的",
                collapseProgress: headerCollapseProgress
            )

            LazyVStack(spacing: 16) {
                ProfileHeaderCard(card: loader.card, mid: session.mid)
                ProfileQuickActions(mid: session.mid)
                ProfileSystemSection()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .coordinateSpace(name: "profile-scroll")
        .modifier(ScrollOffsetCollapseDriver(progress: $headerCollapseProgress))
        .background(IbiliTheme.background)
        .scrollContentBackground(.hidden)
        .task(id: session.mid) {
            await loader.load(mid: session.mid)
        }
        .refreshable {
            await loader.reload(mid: session.mid)
        }
        .tint(IbiliTheme.accent)
    }
}

// MARK: - Header

private struct ProfileHeaderCard: View {
    let card: UserCardDTO?
    let mid: Int64

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                AvatarRing(url: card?.face ?? "", size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card?.name ?? "—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(IbiliTheme.textPrimary)
                        .lineLimit(1)
                    if let sign = card?.sign, !sign.isEmpty {
                        Text(sign)
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text("UID \(mid > 0 ? String(mid) : "—")")
                            .font(.footnote)
                            .foregroundStyle(IbiliTheme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                NavigationLink {
                    RelationListView(vmid: mid, scope: .followings, title: "关注")
                } label: {
                    statPill(value: card?.following ?? 0, label: "关注")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 28)
                NavigationLink {
                    RelationListView(vmid: mid, scope: .followers, title: "粉丝")
                } label: {
                    statPill(value: card?.follower ?? 0, label: "粉丝")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 28)
                statPill(value: card?.archiveCount ?? 0, label: "投稿")
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    private func statPill(value: Int64, label: String) -> some View {
        VStack(spacing: 2) {
            Text(BiliFormat.compactCount(value))
                .font(.callout.weight(.semibold))
                .foregroundStyle(IbiliTheme.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(IbiliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AvatarRing: View {
    let url: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [IbiliTheme.accent.opacity(0.9), IbiliTheme.accent.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: size + 6, height: size + 6)
            RemoteImage(url: url,
                        contentMode: .fill,
                        targetPointSize: CGSize(width: size, height: size),
                        quality: 75)
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
        .frame(width: size + 8, height: size + 8)
    }
}

// MARK: - Quick actions

private struct ProfileQuickActions: View {
    let mid: Int64

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            NavigationLink {
                HistoryListView()
            } label: {
                ActionTile(symbol: "clock.arrow.circlepath", title: "历史记录")
            }
            NavigationLink {
                WatchLaterListView()
            } label: {
                ActionTile(symbol: "list.bullet.rectangle.portrait", title: "稍后再看")
            }
            NavigationLink {
                FavoritesFolderListView(mid: mid)
            } label: {
                ActionTile(symbol: "star.fill", title: "我的收藏")
            }
            NavigationLink {
                BangumiFollowListView(mid: mid)
            } label: {
                ActionTile(symbol: "tv", title: "我的追番")
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ActionTile: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(IbiliTheme.accent.opacity(0.12))
                )
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(IbiliTheme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(IbiliTheme.surface)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - System section

private struct ProfileSystemSection: View {
    @EnvironmentObject var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                SettingsView()
            } label: {
                systemRow(symbol: "rectangle.grid.2x2", title: "设置")
            }
            Divider().padding(.leading, 56)
            NavigationLink {
                LogsView()
            } label: {
                systemRow(symbol: "doc.text.magnifyingglass", title: "应用日志")
            }
            Divider().padding(.leading, 56)
            Button(role: .destructive) {
                session.logout()
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                        .frame(width: 28, height: 28)
                    Text("退出登录")
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(IbiliTheme.surface)
        )
    }

    @ViewBuilder
    private func systemRow(symbol: String, title: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(IbiliTheme.accent)
                .frame(width: 28, height: 28)
            Text(title)
                .foregroundStyle(IbiliTheme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(IbiliTheme.textSecondary.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Loader

@MainActor
final class ProfileHeaderLoader: ObservableObject {
    @Published private(set) var card: UserCardDTO?
    private var inflight: Int64 = 0

    func load(mid: Int64) async {
        guard mid > 0, mid != inflight, card?.mid != mid else { return }
        await reload(mid: mid)
    }

    func reload(mid: Int64) async {
        guard mid > 0 else { return }
        inflight = mid
        let result: UserCardDTO? = await Task.detached {
            try? CoreClient.shared.userCard(mid: mid)
        }.value
        if let result, result.mid == mid {
            self.card = result
        }
        inflight = 0
    }
}
