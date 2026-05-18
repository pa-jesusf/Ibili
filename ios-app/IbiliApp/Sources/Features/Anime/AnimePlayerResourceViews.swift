import Foundation
import SwiftUI

struct AnimePlayerPlaceholder: View {
    let coverURL: String
    let title: String
    let episodeTitle: String
    let isLoading: Bool
    let errorText: String?
    let onRetry: () -> Void

    var body: some View {
        ZStack {
            RemoteImage(url: coverURL, targetPointSize: CGSize(width: 640, height: 360), quality: 70)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay(Color.black.opacity(0.64))
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2.weight(.semibold))
                } else {
                    Image(systemName: "play.tv")
                        .font(.title2.weight(.semibold))
                }
                VStack(spacing: 4) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                .multilineTextAlignment(.center)
                if errorText != nil {
                    Button("重试", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
        }
    }

    private var statusText: String {
        if let errorText { return errorText }
        return isLoading ? "正在检索 \(episodeTitle)" : episodeTitle
    }
}

struct AnimeSourceReportRow: View {
    let report: AnimeMediaSourceReportDTO
    var showsCaptchaButton = true
    let onSolveCaptcha: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.sourceName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if report.supportedCount > 0 {
                Text("\(report.supportedCount)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(IbiliTheme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(IbiliTheme.accent.opacity(0.12), in: Capsule())
            } else if report.status == "captcha", showsCaptchaButton {
                Button("验证", action: onSolveCaptcha)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch report.status {
        case "found":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(IbiliTheme.accent)
        case "searching", "pending":
            ProgressView().controlSize(.small)
        case "failed":
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case "captcha":
            Image(systemName: "lock.shield").foregroundStyle(.orange)
        case "unsupported":
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private var detailText: String {
        if !report.message.isEmpty {
            if report.status == "captcha", !report.captchaKind.isEmpty {
                return report.captchaKind
            }
            return report.message
        }
        if report.attemptedQueries > 0 {
            return "查询 \(report.succeededQueries)/\(report.attemptedQueries)"
        }
        return "等待检索"
    }
}

struct AnimeActiveResourceRow: View {
    let candidate: AnimeMediaCandidateDTO
    let format: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(IbiliTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在播放")
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                Text([candidate.sourceName, resourceLabel, format.uppercased()]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(IbiliTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var resourceLabel: String {
        if !candidate.qualityLabel.isEmpty { return candidate.qualityLabel }
        if candidate.isSniffableWeb { return "网页嗅探" }
        return candidate.kind.uppercased()
    }
}

struct AnimeCandidateListView: View {
    let candidates: [AnimeMediaCandidateDTO]
    let diagnostics: AnimeMediaFetchDiagnosticsDTO?
    let isLoading: Bool
    let activeCandidateID: String?
    let activePlayURL: String?
    let onPick: (AnimeMediaCandidateDTO) -> Void
    let onSolveCaptcha: (AnimeMediaSourceReportDTO) -> Void
    let onManageSources: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AnimeResourceViewMode = .simple

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("显示模式", selection: $mode) {
                    Text("简单模式").tag(AnimeResourceViewMode.simple)
                    Text("详细模式").tag(AnimeResourceViewMode.detail)
                }
                .pickerStyle(.segmented)

                if candidates.isEmpty, diagnostics?.sourceReports.isEmpty != false {
                    emptyState(title: isLoading ? "正在检索资源" : "没有找到资源", symbol: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                } else {
                    resourceGroups
                }

                if mode == .detail, let diagnostics {
                    diagnosticsSection(diagnostics)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(IbiliTheme.background)
        .navigationTitle("选择数据源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onManageSources) {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    private var resourceGroups: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(groupedSources) { group in
                AnimeResourceSourceGroupView(
                    group: group,
                    mode: mode,
                    isLoading: isLoading,
                    activeCandidateID: activeCandidateID,
                    activePlayURL: activePlayURL,
                    onPick: onPick,
                    onSolveCaptcha: onSolveCaptcha
                )
            }
        }
    }

    private func diagnosticsSection(_ diagnostics: AnimeMediaFetchDiagnosticsDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("诊断")
                .font(.headline)
            HStack(spacing: 8) {
                diagnosticsPill("查询", "\(diagnostics.succeededQueries)/\(diagnostics.attemptedQueries)")
                diagnosticsPill("可播", "\(diagnostics.supportedCandidates)")
                diagnosticsPill("不可播", "\(diagnostics.unsupportedCandidates)")
            }
            ForEach(diagnostics.messages.prefix(4), id: \.self) { message in
                Text(message)
                    .font(.caption)
                    .foregroundStyle(IbiliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(IbiliTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func diagnosticsPill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(IbiliTheme.textPrimary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(IbiliTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var groupedSources: [AnimeResourceSourceGroup] {
        var groups: [AnimeResourceSourceGroup] = []
        var indexByID: [String: Int] = [:]
        for report in diagnostics?.sourceReports ?? [] {
            let group = AnimeResourceSourceGroup(report: report, candidates: candidates.filter { $0.sourceID == report.sourceID })
            indexByID[report.sourceID] = groups.count
            groups.append(group)
        }
        for candidate in candidates where indexByID[candidate.sourceID] == nil {
            indexByID[candidate.sourceID] = groups.count
            groups.append(AnimeResourceSourceGroup(
                report: AnimeMediaSourceReportDTO.placeholder(for: candidate),
                candidates: [candidate]
            ))
        }
        for candidate in candidates {
            guard let index = indexByID[candidate.sourceID],
                  !groups[index].candidates.contains(where: { $0.id == candidate.id }) else { continue }
            groups[index].candidates.append(candidate)
        }
        return groups.filter { mode == .detail || !$0.candidates.isEmpty || $0.report.status == "captcha" }
    }
}

private enum AnimeResourceViewMode: String, Hashable {
    case simple
    case detail
}

private struct AnimeResourceSourceGroup: Identifiable {
    let report: AnimeMediaSourceReportDTO
    var candidates: [AnimeMediaCandidateDTO]
    var id: String { report.sourceID }
}

private struct ResourceGroupBackground: ShapeStyle {
    let isActive: Bool

    func resolve(in environment: EnvironmentValues) -> Color {
        isActive ? IbiliTheme.accent.opacity(0.12) : IbiliTheme.surface
    }
}

private struct AnimeResourceSourceGroupView: View {
    let group: AnimeResourceSourceGroup
    let mode: AnimeResourceViewMode
    let isLoading: Bool
    let activeCandidateID: String?
    let activePlayURL: String?
    let onPick: (AnimeMediaCandidateDTO) -> Void
    let onSolveCaptcha: (AnimeMediaSourceReportDTO) -> Void

    var body: some View {
        content
        .padding(12)
        .background(ResourceGroupBackground(isActive: hasActiveCandidate), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(hasActiveCandidate ? IbiliTheme.accent.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if mode == .simple {
            simpleContent
        } else {
            detailContent
        }
    }

    private var simpleContent: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 8) {
                sourceBadge
                    .frame(width: 22, height: 22)
                Text(group.report.sourceName)
                    .font(.headline)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 118, alignment: .leading)

            if group.candidates.isEmpty {
                emptySimpleStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(group.candidates) { candidate in
                        resourceButton(for: candidate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                sourceBadge
                Text(group.report.sourceName)
                    .font(.headline)
                    .foregroundStyle(IbiliTheme.textPrimary)
                    .lineLimit(1)
                if group.report.status == "captcha" {
                    Text("需要处理验证码")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if group.candidates.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(IbiliTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }

            if group.candidates.isEmpty {
                if group.report.status == "captcha" {
                    captchaButton
                } else {
                    AnimeSourceReportRow(report: group.report, showsCaptchaButton: true) {
                        onSolveCaptcha(group.report)
                    }
                }
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(group.candidates) { candidate in
                        resourceButton(for: candidate)
                    }
                }
                AnimeSourceReportRow(report: group.report, showsCaptchaButton: true) {
                    onSolveCaptcha(group.report)
                }
            }
        }
    }

    @ViewBuilder
    private var emptySimpleStatus: some View {
        if group.report.status == "captcha" {
            Button {
                onSolveCaptcha(group.report)
            } label: {
                Text("需要处理验证码")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        } else {
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(IbiliTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
        }
    }

    private var captchaButton: some View {
        Button("打开验证") {
            onSolveCaptcha(group.report)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .buttonStyle(.plain)
    }

    private func resourceButton(for candidate: AnimeMediaCandidateDTO) -> some View {
        Button {
            guard candidate.isPlayableOrSniffable else { return }
            onPick(candidate)
        } label: {
            AnimeResourceChip(
                candidate: candidate,
                isActive: isActive(candidate),
                mode: mode
            )
        }
        .buttonStyle(.plain)
        .disabled(!candidate.isPlayableOrSniffable || isLoading)
    }

    private var hasActiveCandidate: Bool {
        group.candidates.contains(where: isActive(_:))
    }

    private func isActive(_ candidate: AnimeMediaCandidateDTO) -> Bool {
        if let activeCandidateID {
            return candidate.id == activeCandidateID
        }
        return candidate.url == activePlayURL
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if group.report.status == "found" || !group.candidates.isEmpty {
            Image(systemName: hasActiveCandidate ? "play.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasActiveCandidate ? IbiliTheme.accent : .green)
        } else if group.report.status == "captcha" {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
        } else if group.report.status == "failed" {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
        } else if group.report.status == "searching" || group.report.status == "pending" {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if !group.report.message.isEmpty { return group.report.message }
        if group.report.status == "unsupported" { return "暂不支持" }
        if group.report.status == "failed" { return "检索失败" }
        if group.report.attemptedQueries > 0 { return "未找到可播线路" }
        return "等待检索"
    }
}

private struct AnimeResourceChip: View {
    let candidate: AnimeMediaCandidateDTO
    let isActive: Bool
    let mode: AnimeResourceViewMode

    var body: some View {
        HStack(spacing: 5) {
            leadingIcon
            Text(chipTitle)
                .font(mode == .simple ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                .lineLimit(mode == .simple ? 1 : 2)
                .truncationMode(.tail)
                .minimumScaleFactor(mode == .simple ? 0.86 : 1)
        }
        .frame(minHeight: 34, alignment: .leading)
        .foregroundStyle(isActive ? .white : (candidate.isPlayableOrSniffable ? IbiliTheme.textPrimary : IbiliTheme.textSecondary))
        .frame(maxWidth: mode == .simple ? 150 : 220, alignment: .leading)
        .padding(.horizontal, mode == .simple ? 12 : 13)
        .padding(.vertical, mode == .simple ? 7 : 8)
        .background(isActive ? IbiliTheme.accent : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(candidate.isPlayableOrSniffable ? IbiliTheme.textSecondary.opacity(0.35) : Color.clear, lineWidth: isActive ? 0 : 1)
        )
        .opacity(candidate.isPlayableOrSniffable ? 1 : 0.65)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if isActive {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
        } else if mode == .detail, candidate.isSniffableWeb {
            Image(systemName: "globe")
                .font(.caption.weight(.semibold))
        } else if mode == .detail, !candidate.isSupported {
            Image(systemName: "slash.circle")
                .font(.caption.weight(.semibold))
        }
    }

    private var chipTitle: String {
        mode == .simple ? candidate.resourceCapsuleTitle : candidate.resourceDetailTitle
    }
}

extension AnimeMediaCandidateDTO {
    var isSniffableWeb: Bool {
        kind == "web" && (URL(string: url) != nil || URL(string: pageURL) != nil)
    }

    var isPlayableOrSniffable: Bool {
        isSupported || isSniffableWeb
    }

    var resourceCapsuleTitle: String {
        if let channel = extractedChannelTitle {
            return channel
        }
        if !qualityLabel.isEmpty {
            return qualityLabel
        }
        if let short = extractedShortTitle {
            return short
        }
        if isSniffableWeb {
            return "网页嗅探"
        }
        return kind.uppercased()
    }

    var resourceDetailTitle: String {
        if let channel = extractedChannelTitle {
            if !qualityLabel.isEmpty {
                return "\(channel) · \(qualityLabel)"
            }
            return channel
        }
        if !qualityLabel.isEmpty {
            return qualityLabel
        }
        if let short = extractedShortTitle {
            return short
        }
        if isSniffableWeb {
            return "网页嗅探"
        }
        return kind.uppercased()
    }

    private var titleParts: [String] {
        title
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != sourceName }
    }

    private var extractedChannelTitle: String? {
        let parts = titleParts
        if parts.count >= 3 {
            let channel = parts[parts.count - 2]
            if !channel.isEpisodeLikeLabel {
                return channel
            }
        }
        if let match = title.firstMatch(
            #"((?:独家|超快|高清|蓝光|巨卡|备用|播放|线路|路线|主线|新番主线|自建蓝光|TT备用|FF备用|ZJ蓝光)[^·\s，,。]*)"#
        ), !match.isEmpty {
            return match
        }
        return nil
    }

    private var extractedShortTitle: String? {
        let parts = titleParts
        if let last = parts.last, last.count <= 8 {
            return last
        }
        return nil
    }
}

private extension String {
    var isEpisodeLikeLabel: Bool {
        range(of: #"^(?:第?\s*\d+(?:[话話集期]|$)|EP\s*\d+|\d+\s*$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AnimeSourceDTO {
    var searchUseSubjectNamesCount: Int {
        let raw = arguments.objectValue["searchConfig"]?.objectValue["searchUseSubjectNamesCount"]?.intValue ?? 1
        return max(1, raw)
    }

    var requestIntervalMs: Int {
        max(0, arguments.objectValue["searchConfig"]?.objectValue["requestInterval"]?.intValue ?? 0)
    }
}

extension AnyCodableValue {
    var objectValue: [String: AnyCodableValue] {
        if case .object(let value) = self {
            return value
        }
        return [:]
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}

extension AnimeMediaSourceReportDTO {
    func replacing(
        status: String? = nil,
        stateID: String? = nil,
        isWorking: Bool? = nil,
        isTemporarilyEnabled: Bool? = nil,
        message: String? = nil,
        captchaURL: String? = nil,
        captchaKind: String? = nil
    ) -> AnimeMediaSourceReportDTO {
        AnimeMediaSourceReportDTO(
            sourceID: sourceID,
            sourceName: sourceName,
            factoryID: factoryID,
            stateID: stateID ?? self.stateID,
            isWorking: isWorking ?? self.isWorking,
            isTemporarilyEnabled: isTemporarilyEnabled ?? self.isTemporarilyEnabled,
            attemptedQueries: attemptedQueries,
            succeededQueries: succeededQueries,
            failedQueries: failedQueries,
            candidateCount: candidateCount,
            supportedCount: supportedCount,
            status: status ?? self.status,
            message: message ?? self.message,
            captchaURL: captchaURL ?? self.captchaURL,
            captchaKind: captchaKind ?? self.captchaKind
        )
    }

    func withTemporaryEnabled(_ value: Bool) -> AnimeMediaSourceReportDTO {
        replacing(isTemporarilyEnabled: value)
    }

    func finishedFailure(message: String) -> AnimeMediaSourceReportDTO {
        AnimeMediaSourceReportDTO(
            sourceID: sourceID,
            sourceName: sourceName,
            factoryID: factoryID,
            stateID: "failed",
            isWorking: false,
            isTemporarilyEnabled: isTemporarilyEnabled,
            attemptedQueries: max(attemptedQueries, 1),
            succeededQueries: succeededQueries,
            failedQueries: max(failedQueries, 1),
            candidateCount: candidateCount,
            supportedCount: supportedCount,
            status: "failed",
            message: message,
            captchaURL: captchaURL,
            captchaKind: captchaKind
        )
    }

    static func placeholder(for candidate: AnimeMediaCandidateDTO) -> AnimeMediaSourceReportDTO {
        AnimeMediaSourceReportDTO(
            sourceID: candidate.sourceID,
            sourceName: candidate.sourceName,
            factoryID: "",
            stateID: candidate.isPlayableOrSniffable ? "found" : "unsupported",
            isWorking: false,
            isTemporarilyEnabled: false,
            attemptedQueries: 0,
            succeededQueries: 0,
            failedQueries: 0,
            candidateCount: 1,
            supportedCount: candidate.isPlayableOrSniffable ? 1 : 0,
            status: candidate.isPlayableOrSniffable ? "found" : "unsupported",
            message: "",
            captchaURL: "",
            captchaKind: ""
        )
    }
}
