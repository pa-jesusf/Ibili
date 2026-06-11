import SwiftUI

struct MediaHero<Meta: View, Footer: View>: View {
    let coverURL: String
    let title: String
    var originalTitle: String? = nil
    var dateText: String? = nil
    var progressText: String? = nil
    let meta: Meta
    let footer: Footer

    init(
        coverURL: String,
        title: String,
        originalTitle: String? = nil,
        dateText: String? = nil,
        progressText: String? = nil,
        @ViewBuilder meta: () -> Meta,
        @ViewBuilder footer: () -> Footer
    ) {
        self.coverURL = coverURL
        self.title = title
        self.originalTitle = originalTitle
        self.dateText = dateText
        self.progressText = progressText
        self.meta = meta()
        self.footer = footer()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: coverURL, targetPointSize: CGSize(width: 760, height: 760), quality: 72)
                .scaledToFill()
                .frame(height: 356)
                .frame(maxWidth: .infinity)
                .clipped()
                .blur(radius: 22)
                .scaleEffect(1.12)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.10),
                            Color.black.opacity(0.56),
                            IbiliTheme.background.opacity(0.90),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    RemoteImage(url: coverURL, targetPointSize: CGSize(width: 260, height: 370), quality: 86)
                        .frame(width: 130, height: 184)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                            .minimumScaleFactor(0.86)
                            .textSelection(.enabled)

                        if let originalTitle, !originalTitle.isEmpty, originalTitle != title {
                            Text(originalTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }

                        if let dateText, !dateText.isEmpty {
                            MediaHeroCapsule(text: dateText)
                        }

                        if let progressText, !progressText.isEmpty {
                            Text(progressText)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.84))
                                .lineLimit(1)
                        }

                        meta
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                footer
            }
            .padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MediaHeroCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 0.7))
    }
}
