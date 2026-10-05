import SwiftUI

extension View {
    func mediaCardChrome(width: CGFloat) -> some View {
        modifier(MediaCardChrome(width: width))
    }
}

private struct MediaCardChrome: ViewModifier {
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MediaCardLayout(width: width, showsAuthor: false, showsMetadata: false).cornerRadius,
                                     style: .continuous)
        content
            .background(IbiliTheme.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08),
                                        lineWidth: 1 / UIScreen.main.scale))
    }
}

struct MediaCardView: View {
    let model: MediaCardRenderModel
    let width: CGFloat

    var body: some View {
        MediaCardSurface(model: model, width: width)
            .frame(width: width, height: MediaCardContentView.preferredHeight(width: width, model: model))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([model.title, model.author].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

/// The same native presentation used by home collection cells. SwiftUI owns
/// the surrounding navigation button and overflow menu, so this is visual only.
private struct MediaCardSurface: UIViewRepresentable {
    let model: MediaCardRenderModel
    let width: CGFloat

    func makeUIView(context: Context) -> MediaCardContentView {
        MediaCardContentView()
    }

    func updateUIView(_ view: MediaCardContentView, context: Context) {
        view.configure(model: model, targetWidth: width)
    }

    static func dismantleUIView(_ view: MediaCardContentView, coordinator: ()) {
        view.reset()
    }
}

struct MediaRowView: View {
    let model: MediaCardRenderModel
    var progress: Double = 0
    var durationOverride: String? = nil
    var coverSize = CGSize(width: 120, height: 75)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !model.author.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                            .imageScale(.small)
                        Text(model.author)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(IbiliTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    if model.play > 0 {
                        Label(BiliFormat.compactCount(model.play), systemImage: "play.fill")
                    }
                    if model.danmaku > 0 {
                        Label(BiliFormat.compactCount(model.danmaku), systemImage: "text.bubble")
                    }
                    if model.like > 0 {
                        Label(BiliFormat.compactCount(model.like), systemImage: "hand.thumbsup")
                    }
                }
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(
                url: model.cover,
                contentMode: .fill,
                targetPointSize: CGSize(width: coverSize.width * 2, height: coverSize.height * 2),
                quality: model.imageQuality ?? 75
            )
            .frame(width: coverSize.width, height: coverSize.height)
            .clipped()
            .overlay(alignment: .bottom) {
                if progress > 0.001 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.25))
                            Rectangle().fill(IbiliTheme.accent)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let label = durationOverride ?? formattedDuration {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(6)
            }
        }
    }

    private var formattedDuration: String? {
        model.durationSec > 0 ? BiliFormat.duration(model.durationSec) : nil
    }
}
