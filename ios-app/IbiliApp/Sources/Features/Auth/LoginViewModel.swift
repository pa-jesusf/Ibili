import Foundation
import Combine

@MainActor
final class LoginViewModel: ObservableObject {
    enum State: Equatable {
        case idle, loadingQR, waiting(qrUrl: String), scanned(qrUrl: String)
        case expired, failed(String), success
    }
    struct Services {
        var qrStart: () async throws -> TvQrStartDTO
        var qrPoll: (String) async throws -> TvQrPollDTO
        var submit: (LoginAction, LoginRequestDTO) async throws -> LoginResultDTO
        static var live: Self {
            Self(
                qrStart: { try await Task.detached { try CoreClient.shared.tvQrStart() }.value },
                qrPoll: { code in try await Task.detached { try CoreClient.shared.tvQrPoll(authCode: code) }.value },
                submit: { action, request in
                    try await Task.detached { try CoreClient.shared.login(action, request: request) }.value
                })
        }
    }
    private struct Operation {
        var action: LoginAction
        var request: LoginRequestDTO
    }
    private struct SMSTicket {
        let tel: String
        let country: String
        let key: String
        let sentAt: Date
        func matches(tel: String, country: String, now: Date) -> Bool {
            self.tel == tel && self.country == country && now.timeIntervalSince(sentAt) < 300
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var method: LoginMethod = .qr
    @Published private(set) var isBusy = false
    @Published private(set) var isSendingSMS = false
    @Published private(set) var message: String?
    @Published var username = ""
    @Published var password = ""
    @Published var phone = ""
    @Published var countryCode = "86"
    @Published var smsCode = ""
    @Published var cookie = ""
    @Published private(set) var captcha: LoginCaptchaChallenge?
    @Published private(set) var phoneRisk: LoginPhoneRisk?
    @Published var riskCode = ""
    @Published private var smsTicket: SMSTicket?
    @Published private var riskTicket: SMSTicket?

    private let services: Services
    private var task: Task<Void, Never>?
    private var generation = 0
    private var pendingCaptchaOperation: Operation?
    private weak var session: AppSession?

    init(services: Services = .live) { self.services = services }
    func bind(session: AppSession) { self.session = session }

    func select(_ method: LoginMethod) {
        // Sending an SMS is an external side effect: keep its ticket/cooldown
        // until the server responds, even if the user taps another tab.
        guard !isSendingSMS else { return }
        guard self.method != method else { return }
        cancel()
        self.method = method
        message = nil
        if method == .qr { start() }
    }

    func start() {
        cancel()
        state = .loadingQR
        isBusy = true
        let revision = generation
        task = Task { [weak self, services] in
            do {
                let qr = try await services.qrStart()
                guard let self, self.isCurrent(revision) else { return }
                self.state = .waiting(qrUrl: qr.url)
                self.isBusy = false
                let deadline = Date().addingTimeInterval(180)
                while self.isCurrent(revision), Date() < deadline {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard self.isCurrent(revision) else { return }
                    let result = try await services.qrPoll(qr.authCode)
                    guard self.isCurrent(revision) else { return }
                    switch result {
                    case .pending: self.state = .waiting(qrUrl: qr.url)
                    case .scanned: self.state = .scanned(qrUrl: qr.url)
                    case .expired: self.state = .expired; return
                    case .confirmed(let credentials):
                        self.complete(credentials)
                        return
                    }
                }
                if self.isCurrent(revision) { self.state = .expired }
            } catch {
                guard let self, self.isCurrent(revision) else { return }
                self.isBusy = false
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func submit() {
        guard !isBusy else { return }
        let request: LoginRequestDTO
        let action: LoginAction
        switch method {
        case .qr: start(); return
        case .password:
            guard !username.isEmpty, !password.isEmpty else { message = "请输入账号和密码"; return }
            request = LoginRequestDTO(username: username, password: password)
            action = .password
        case .sms:
            guard let ticket = smsTicket, ticket.matches(tel: phone, country: countryCode, now: Date()) else {
                message = "请先为当前手机号获取短信验证码（有效期 5 分钟）"; return
            }
            guard !smsCode.isEmpty else { message = "请输入短信验证码"; return }
            request = LoginRequestDTO(tel: phone, country_code: countryCode, code: smsCode, captcha_key: ticket.key)
            action = .sms
        case .cookie:
            guard !cookie.isEmpty else { message = "请输入 Cookie"; return }
            request = LoginRequestDTO(cookie: cookie)
            action = .cookie
        }
        perform(Operation(action: action, request: request))
    }

    func sendSMS() {
        guard !isBusy, smsCooldownRemaining(at: Date()) == 0 else { return }
        guard !phone.isEmpty, !countryCode.isEmpty else { message = "请输入国际区号和手机号"; return }
        perform(Operation(action: .sendSMS, request: LoginRequestDTO(tel: phone, country_code: countryCode)))
    }

    func smsCooldownRemaining(at date: Date) -> Int {
        guard let ticket = smsTicket else { return 0 }
        return max(0, Int(ceil(60 - date.timeIntervalSince(ticket.sentAt))))
    }

    func riskCooldownRemaining(at date: Date) -> Int {
        guard let ticket = riskTicket else { return 0 }
        return max(0, Int(ceil(60 - date.timeIntervalSince(ticket.sentAt))))
    }

    func sendRiskSMS() {
        guard !isBusy, let phoneRisk, riskCooldownRemaining(at: Date()) == 0 else { return }
        perform(Operation(action: .captcha, request: LoginRequestDTO(risk: phoneRisk)))
    }

    func verifyRiskSMS() {
        guard !isBusy, let phoneRisk else { return }
        guard let ticket = riskTicket, Date().timeIntervalSince(ticket.sentAt) < 300 else {
            message = "请先获取安全验证短信"; return
        }
        guard !riskCode.isEmpty else { message = "请输入短信验证码"; return }
        perform(Operation(action: .riskVerify,
                          request: LoginRequestDTO(code: riskCode, captcha_key: ticket.key, risk: phoneRisk)))
    }

    func completeCaptcha(_ proof: LoginCaptchaProof) {
        guard var operation = pendingCaptchaOperation else { return }
        pendingCaptchaOperation = nil
        captcha = nil
        operation.request.captcha = proof
        perform(operation)
    }

    func cancelCaptcha() {
        captcha = nil
        pendingCaptchaOperation = nil
    }

    func cancelRiskVerification() {
        guard !isSendingSMS else { return }
        cancel()
        message = "已取消安全验证，可重新登录或选择其他方式"
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isBusy = false
        isSendingSMS = false
        captcha = nil
        pendingCaptchaOperation = nil
        phoneRisk = nil
        riskTicket = nil
        riskCode = ""
        password = ""
        cookie = ""
        state = .idle
    }

    private func perform(_ operation: Operation) {
        generation += 1
        let revision = generation
        task?.cancel()
        isBusy = true
        isSendingSMS = operation.action == .sendSMS || operation.action == .riskSend
        message = nil
        task = Task { [weak self, services] in
            do {
                let result = try await services.submit(operation.action, operation.request)
                guard let self, self.isCurrent(revision) else { return }
                self.isBusy = false
                self.isSendingSMS = false
                switch result {
                case .confirmed(let credentials): self.complete(credentials)
                case .captcha(let challenge):
                    var continuation = operation
                    if operation.action == .captcha { continuation.action = .riskSend }
                    self.pendingCaptchaOperation = continuation
                    self.captcha = challenge
                case .phoneVerification(let risk):
                    self.password = ""
                    self.phoneRisk = risk
                    self.riskTicket = nil
                    self.message = "本次登录需要验证账号绑定的手机号"
                case .smsSent(let key):
                    let ticket = SMSTicket(tel: operation.request.tel ?? "", country: operation.request.country_code ?? "",
                                           key: key, sentAt: Date())
                    if operation.action == .riskSend { self.riskTicket = ticket }
                    else { self.smsTicket = ticket }
                    self.message = "短信验证码已发送"
                }
            } catch {
                guard let self, self.isCurrent(revision) else { return }
                self.isBusy = false
                self.isSendingSMS = false
                self.message = error.localizedDescription
            }
        }
    }

    private func isCurrent(_ revision: Int) -> Bool { generation == revision && !Task.isCancelled }

    private func complete(_ credentials: PersistedSessionDTO) {
        // Only the surviving UI attempt may install and persist its credentials.
        session?.didLogin(credentials)
        password = ""
        cookie = ""
        smsCode = ""
        riskCode = ""
        phoneRisk = nil
        pendingCaptchaOperation = nil
        captcha = nil
        state = .success
        isBusy = false
    }
}
