import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loadingQR
        case waiting(qrUrl: String)
        case scanned(qrUrl: String)
        case expired
        case failed(String)
        case success
    }

    @Published private(set) var state: State = .idle
    private var authCode: String = ""
    private var lastQRUrl: String?
    private var pollTask: Task<Void, Never>?
    private weak var session: AppSession?

    func bind(session: AppSession) { self.session = session }

    func start() {
        pollTask?.cancel()
        state = .loadingQR
        AppLog.info("auth", "开始请求扫码登录二维码")
        Task {
            do {
                let s = try await Task.detached { try CoreClient.shared.tvQrStart() }.value
                self.authCode = s.authCode
                self.lastQRUrl = s.url
                self.state = .waiting(qrUrl: s.url)
                AppLog.info("auth", "二维码获取成功，开始轮询登录状态")
                self.beginPolling()
            } catch {
                self.state = .failed(error.localizedDescription)
                AppLog.error("auth", "二维码获取失败", error: error)
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        AppLog.debug("auth", "取消扫码登录轮询")
    }

    private func beginPolling() {
        let code = authCode
        pollTask = Task { [weak self] in
            AppLog.debug("auth", "开始轮询扫码登录状态")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                let resultRes = await Task.detached { () -> Result<TvQrPollDTO, Error> in
                    do { return .success(try CoreClient.shared.tvQrPoll(authCode: code)) }
                    catch { return .failure(error) }
                }.value
                guard let self = self else { return }
                switch resultRes {
                case .failure(let e):
                    self.state = .failed(e.localizedDescription)
                    AppLog.error("auth", "扫码登录轮询失败", error: e)
                    return
                case .success(let poll):
                    switch poll {
                    case .pending:
                        // Treat any non-confirmed, non-scanned state as waiting; never
                        // regress to a "scanned" label without an explicit signal.
                        if case .scanned = self.state {
                            self.state = .waiting(qrUrl: self.lastQRUrl ?? "")
                        }
                    case .scanned:
                        if case .waiting(let u) = self.state {
                            self.state = .scanned(qrUrl: u)
                            AppLog.info("auth", "二维码已扫码，等待手机确认")
                        }
                    case .expired:
                        self.state = .expired
                        AppLog.warning("auth", "二维码已过期")
                        return
                    case .confirmed(let s):
                        self.session?.didLogin(s)
                        self.state = .success
                        AppLog.info("auth", "扫码登录完成", metadata: [
                            "mid": String(s.mid),
                        ])
                        return
                    }
                }
            }
        }
    }
}
