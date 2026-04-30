import SwiftUI

/// Multi-line text with a "展开 / 收起" toggle. Used for the long
/// video description and uploader bio. Layout follows Apple's
/// Photos / App Store description pattern: collapsed clamp shows the
/// configured number of lines with a fade-out gradient overlay; the
/// affordance label is plain text in the accent colour. Tapping
/// anywhere on the text body expands.
struct ExpandableText: View {
    let text: String
    var lineLimit: Int = 3
    var expandLabel: String = "展开"
    var collapseLabel: String = "收起"
    var font: Font = .body
    var textColor: Color = IbiliTheme.textPrimary

    @State private var expanded: Bool = false
    @State private var truncates: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(font)
                .foregroundStyle(textColor)
                .lineSpacing(2)
                .lineLimit(expanded ? nil : lineLimit)
                .background(measureGeometry)
                .animation(.easeInOut(duration: 0.2), value: expanded)
                .onTapGesture { if truncates { withAnimation { expanded.toggle() } } }

            if truncates {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text(expanded ? collapseLabel : expandLabel)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(IbiliTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Render the same text once unconstrained off-screen to detect
    /// whether the visible clamp truncates. Avoids preference-key
    /// flicker that the naive `Text("\n").lineLimit` trick produces.
    private var measureGeometry: some View {
        Text(text)
            .font(font)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(GeometryReader { full in
                Text(text)
                    .font(font)
                    .lineSpacing(2)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { clipped in
                        Color.clear.onAppear {
                            truncates = clipped.size.height < full.size.height - 1
                        }
                    })
                    .hidden()
            })
    }
}
