import SwiftUI

struct AnimePlayerEpisodeChip: View {
    let episode: AnimeEpisodeDTO
    let index: Int
    let isCurrent: Bool
    let stateLabel: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .font(.caption2.weight(.bold).monospacedDigit())
                    if isCurrent {
                        Image(systemName: "waveform")
                            .imageScale(.small)
                    } else if !stateLabel.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .imageScale(.small)
                    }
                }
                .foregroundStyle(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent : IbiliTheme.textSecondary)

                Text(episode.displayTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent : IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 124, height: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isCurrent || !stateLabel.isEmpty ? IbiliTheme.accent.opacity(0.12) : Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isCurrent ? IbiliTheme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
