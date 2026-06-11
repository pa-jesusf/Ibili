import SwiftUI

struct SourcePickerSurface: View {
    let candidates: [AnimeMediaCandidateDTO]
    let diagnostics: AnimeMediaFetchDiagnosticsDTO?
    let isLoading: Bool
    let activeCandidateID: String?
    let activePlayURL: String?
    let onPick: (AnimeMediaCandidateDTO) -> Void
    let onSolveCaptcha: (AnimeMediaSourceReportDTO) -> Void
    let onManageSources: () -> Void

    var body: some View {
        NavigationStack {
            AnimeCandidateListView(
                candidates: candidates,
                diagnostics: diagnostics,
                isLoading: isLoading,
                activeCandidateID: activeCandidateID,
                activePlayURL: activePlayURL,
                onPick: onPick,
                onSolveCaptcha: onSolveCaptcha,
                onManageSources: onManageSources
            )
        }
        .tint(IbiliTheme.accent)
    }
}
