import AVFoundation
import AVKit
import SwiftUI

private struct DiagnosticsSession: Identifiable, Sendable {
    let id: String
    let directory: URL
    let name: String
    let createdAt: Date?
    let workspaceDirectory: URL?

    var hasWorkspace: Bool { workspaceDirectory != nil }
}

@MainActor
private final class DiagnosticsBrowserViewModel: ObservableObject {
    @Published var sessions: [DiagnosticsSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() {
        isLoading = true
        errorMessage = nil

        Task {
            defer { isLoading = false }
            do {
                sessions = try await Task.detached(priority: .utility) {
                    try scanDiagnosticsSessions()
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func buildWorkspace(for session: DiagnosticsSession) {
        errorMessage = nil

        Task {
            do {
                let summary = try await Task.detached(priority: .utility) {
                    let result = try CoreClient.shared.packagingOfflineBuild(
                        diagnosticsDirectory: session.directory.path
                    )
                    return (
                        workspaceRootDirectory: result.workspaceRootDirectory,
                        startupReady: result.startupReady,
                        warningCount: result.warnings.count
                    )
                }.value

                AppLog.info("player", "诊断浏览器：workspace 已生成", metadata: [
                    "directory": session.directory.path,
                    "path": summary.workspaceRootDirectory,
                    "startupReady": String(summary.startupReady),
                    "warnings": String(summary.warningCount),
                ])
                refresh()
            } catch {
                AppLog.error("player", "诊断浏览器：workspace 生成失败", error: error, metadata: [
                    "directory": session.directory.path,
                ])
                errorMessage = "Workspace 生成失败：\(error.localizedDescription)"
            }
        }
    }

}

private func scanDiagnosticsSessions() throws -> [DiagnosticsSession] {
    let documents = try FileManager.default.url(
        for: .documentDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    let root = documents.appendingPathComponent("ibili-diagnostics", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }

    let contents = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    )

    return contents.compactMap { url in
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
        guard values?.isDirectory == true else { return nil }

        let workspaceDirectory = resolveWorkspaceDirectory(for: url)
        return DiagnosticsSession(
            id: url.path,
            directory: url,
            name: url.lastPathComponent,
            createdAt: values?.creationDate,
            workspaceDirectory: workspaceDirectory
        )
    }
    .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
}

private func resolveWorkspaceDirectory(for sessionDirectory: URL) -> URL? {
    let workspaceDirectory = sessionDirectory.appendingPathComponent("packaging-workspace", isDirectory: true)
    let masterPlaylistURL = workspaceDirectory.appendingPathComponent("master.m3u8")
    guard FileManager.default.fileExists(atPath: masterPlaylistURL.path) else { return nil }
    return workspaceDirectory
}

private struct WorkspacePlayback: Identifiable {
    let id = UUID()
    let url: URL
    let proxyToken: String?
    let deliveryKind: String
}

struct DiagnosticsBrowserView: View {
    @StateObject private var viewModel = DiagnosticsBrowserViewModel()
    @State private var activePlayback: WorkspacePlayback?

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.sessions.isEmpty {
                emptyState(
                    title: "暂无诊断数据",
                    symbol: "tray",
                    message: viewModel.errorMessage ?? "触发一次播放失败后，诊断数据将自动导出到此处。"
                )
            } else {
                List {
                    if let message = viewModel.errorMessage {
                        Section {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    ForEach(viewModel.sessions) { session in
                        DiagnosticsSessionRow(
                            session: session,
                            onPlay: { startPlayback(for: session) },
                            onBuild: { viewModel.buildWorkspace(for: session) }
                        )
                    }
                }
                .refreshable {
                    viewModel.refresh()
                }
            }
        }
        .navigationTitle("播放失败诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.refresh()
        }
        .sheet(item: $activePlayback) { playback in
            WorkspacePlayerSheet(playback: playback)
        }
    }

    @MainActor
    private func startPlayback(for session: DiagnosticsSession) {
        guard let workspaceDirectory = session.workspaceDirectory else { return }
        let playbackURL = workspaceDirectory.appendingPathComponent("master.m3u8")
        guard FileManager.default.fileExists(atPath: playbackURL.path) else {
            viewModel.errorMessage = "workspace 缺少 master.m3u8"
            return
        }

        AppLog.info("player", "诊断浏览器：开始播放 workspace", metadata: [
            "delivery": "file",
            "directory": session.directory.path,
            "url": playbackURL.absoluteString,
        ])
        activePlayback = WorkspacePlayback(
            url: playbackURL,
            proxyToken: nil,
            deliveryKind: "file"
        )
    }
}

private struct DiagnosticsSessionRow: View {
    let session: DiagnosticsSession
    let onPlay: () -> Void
    let onBuild: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.name)
                .font(.caption.monospaced())
                .lineLimit(2)

            if let createdAt = session.createdAt {
                Text(Self.dateFormatter.string(from: createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(session.hasWorkspace ? "workspace 已就绪" : "workspace 未生成")
                .font(.caption2)
                .foregroundStyle(session.hasWorkspace ? Color.secondary : .orange)

            HStack(spacing: 10) {
                if session.hasWorkspace {
                    Button(action: onPlay) {
                        Label("播放", systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                } else {
                    Button(action: onBuild) {
                        Label("生成 Workspace", systemImage: "hammer.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WorkspacePlayerSheet: View {
    let playback: WorkspacePlayback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AVPlayerViewControllerRepresentable(url: playback.url)
                .navigationTitle("Workspace 播放")
                .navigationBarTitleDisplayMode(.inline)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") {
                            AppLog.info("player", "诊断浏览器：关闭 workspace 播放", metadata: [
                                "delivery": playback.deliveryKind,
                                "token": playback.proxyToken ?? "-",
                                "url": playback.url.absoluteString,
                            ])
                            dismiss()
                        }
                    }
                }
        }
        .onDisappear {
            if let proxyToken = playback.proxyToken {
                LocalHLSProxy.shared.unregisterWorkspace(token: proxyToken)
            }
        }
    }
}

private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        context.coordinator.attach(to: item)
        AppLog.info("player", "诊断浏览器：workspace AVPlayer 开始加载", metadata: [
            "url": url.absoluteString,
        ])
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
        uiViewController.player?.pause()
        uiViewController.player = nil
    }

    final class Coordinator {
        private let url: URL
        private var itemStatusObservation: NSKeyValueObservation?
        private var errorLogObserver: NSObjectProtocol?
        private var failedToEndObserver: NSObjectProtocol?

        init(url: URL) {
            self.url = url
        }

        func attach(to item: AVPlayerItem) {
            itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [url] item, _ in
                switch item.status {
                case .readyToPlay:
                    AppLog.info("player", "诊断浏览器：workspace AVPlayerItem 就绪", metadata: [
                        "url": url.absoluteString,
                    ])
                case .failed:
                    let detail = item.error?.localizedDescription ?? "unknown"
                    AppLog.error("player", "诊断浏览器：workspace AVPlayerItem 失败", error: item.error, metadata: [
                        "url": url.absoluteString,
                        "detail": detail,
                    ])
                    Self.logErrorEvents(for: item.errorLog(), url: url)
                default:
                    break
                }
            }

            errorLogObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: item,
                queue: .main
            ) { [url] _ in
                Self.logErrorEvents(for: item.errorLog(), url: url)
            }

            failedToEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [url] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                let detail = (error as NSError?)?.localizedDescription ?? String(describing: notification.userInfo ?? [:])
                AppLog.error("player", "诊断浏览器：workspace 播放到结束前失败", error: error, metadata: [
                    "url": url.absoluteString,
                    "detail": detail,
                ])
            }
        }

        func detach() {
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil

            if let errorLogObserver {
                NotificationCenter.default.removeObserver(errorLogObserver)
                self.errorLogObserver = nil
            }
            if let failedToEndObserver {
                NotificationCenter.default.removeObserver(failedToEndObserver)
                self.failedToEndObserver = nil
            }
        }

        private static func logErrorEvents(for log: AVPlayerItemErrorLog?, url: URL) {
            guard let log else { return }
            for event in log.events {
                AppLog.warning("player", "诊断浏览器：workspace error log", metadata: [
                    "url": url.absoluteString,
                    "domain": event.errorDomain,
                    "status": String(event.errorStatusCode),
                    "comment": event.errorComment ?? "-",
                    "uri": event.uri ?? "-",
                ])
            }
        }

        deinit {
            detach()
        }
    }
}