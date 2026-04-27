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
        Task {
            do {
                let s = try await Task.detached { try CoreClient.shared.tvQrStart() }.value
                self.authCode = s.authCode
                self.lastQRUrl = s.url
                self.state = .waiting(qrUrl: s.url)
                self.beginPolling()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func beginPolling() {
        let code = authCode
        pollTask = Task { [weak self] in
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
                        if case .waiting(let u) = self.state { self.state = .scanned(qrUrl: u) }
                    case .expired:
                        self.state = .expired
                        return
                    case .confirmed(let s):
                        self.session?.didLogin(s)
                        self.state = .success
                        return
                    }
                }
            }
        }
    }
}
