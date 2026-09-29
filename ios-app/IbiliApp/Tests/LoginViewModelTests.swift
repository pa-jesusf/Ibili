import XCTest
import Combine
@testable import Ibili

final class LoginViewModelTests: XCTestCase {
    @MainActor
    func testCompletedCaptchaRetainsContentUntilSheetDismisses() async {
        let vm = LoginViewModel(services: services { _, _ in
            .captcha(.init(gt: "gt", challenge: "challenge", token: "token"))
        })
        vm.select(.password)
        vm.username = "user"
        vm.password = "pass"
        vm.submit()
        await settle(vm)
        vm.completeCaptcha(.init(challenge: "challenge", validate: "proof", seccode: "sec", token: "token"), presentationID: vm.captcha!.id)
        XCTAssertNotNil(vm.captcha, "Keep the current content alive through the native dismissal animation")
        XCTAssertFalse(vm.isCaptchaPresented)
        XCTAssertTrue(vm.isBusy)
    }

    @MainActor
    func testContinuationWaitsForDismissalAndIgnoresOldPresentationCallbacks() async {
        var requests: [LoginRequestDTO] = []
        let vm = LoginViewModel(services: services { _, request in
            requests.append(request)
            // The service may reuse the recaptcha token for a second challenge.
            return .captcha(.init(gt: "gt", challenge: "challenge-\(requests.count)", token: "token"))
        })
        await openPasswordChallenge(vm)
        let firstID = vm.captcha!.id
        let proof = LoginCaptchaProof(challenge: "challenge-1", validate: "proof", seccode: "sec", token: "token")
        vm.completeCaptcha(proof, presentationID: firstID)
        XCTAssertEqual(requests.count, 1, "Do not resume HTTP while the sheet is still dismissing")
        vm.captchaPresentationChanged(false, presentationID: firstID)
        vm.cancelCaptcha(presentationID: firstID) // Late close from the completed widget.
        vm.captchaDidDismiss(presentationID: firstID)
        vm.captchaDidDismiss(presentationID: firstID) // Duplicate must not submit twice.
        await settle(vm)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].captcha?.validate, "proof")
        let secondID = vm.captcha!.id
        XCTAssertNotEqual(firstID, secondID)
        vm.completeCaptcha(proof, presentationID: firstID)
        vm.cancelCaptcha(presentationID: firstID)
        vm.captchaPresentationChanged(false, presentationID: firstID)
        vm.captchaDidDismiss(presentationID: firstID)
        XCTAssertTrue(vm.isCaptchaPresented)
        XCTAssertEqual(vm.captcha?.id, secondID)
        vm.captchaPresentationChanged(false, presentationID: secondID) // User swipes down.
        vm.captchaDidDismiss(presentationID: secondID)
        XCTAssertNil(vm.captcha)
        XCTAssertEqual(requests.count, 2, "Cancelling a repeated challenge must not reuse the previous proof")
    }

    @MainActor
    func testContinuationFailureReturnsToLoginWithVisibleError() async {
        var requests = 0
        let vm = LoginViewModel(services: services { _, _ in
            requests += 1
            if requests == 1 { return .captcha(.init(gt: "gt", challenge: "challenge", token: "token")) }
            throw URLError(.notConnectedToInternet)
        })
        await openPasswordChallenge(vm)
        let id = vm.captcha!.id
        vm.completeCaptcha(.init(challenge: "challenge", validate: "proof", seccode: "sec", token: "token"), presentationID: id)
        vm.captchaDidDismiss(presentationID: id)
        await settle(vm)
        XCTAssertFalse(vm.isCaptchaPresented)
        XCTAssertNil(vm.captcha)
        XCTAssertFalse(vm.isBusy)
        XCTAssertNotNil(vm.message)
    }

    @MainActor
    func testSwitchingLoginMethodInvalidatesPendingDismissalContinuation() async {
        var requests = 0
        let vm = LoginViewModel(services: services { _, _ in
            requests += 1
            return .captcha(.init(gt: "gt", challenge: "challenge", token: "token"))
        })
        await openPasswordChallenge(vm)
        let id = vm.captcha!.id
        vm.completeCaptcha(.init(challenge: "challenge", validate: "proof", seccode: "sec", token: "token"), presentationID: id)
        vm.select(.sms)
        vm.captchaDidDismiss(presentationID: id)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(vm.method, .sms)
        XCTAssertNil(vm.captcha)
        XCTAssertFalse(vm.isBusy)
    }

    @MainActor
    private func openPasswordChallenge(_ vm: LoginViewModel) async {
        vm.select(.password)
        vm.username = "user"
        vm.password = "pass"
        vm.submit()
        await settle(vm)
    }

    @MainActor
    private func settle(_ vm: LoginViewModel) async {
        let done = expectation(description: "login operation")
        let subscription = vm.$isBusy.drop(while: { $0 }).prefix(1).sink { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    private func services(_ submit: @escaping (LoginAction, LoginRequestDTO) async throws -> LoginResultDTO) -> LoginViewModel.Services {
        .init(qrStart: { throw URLError(.cancelled) }, qrPoll: { _ in .pending }, submit: submit)
    }

    @MainActor
    func testPasswordChallengeRetriesOriginalInputAndClearsSecretsOnSuccess() async {
        var requests: [LoginRequestDTO] = []
        let challenge = LoginCaptchaChallenge(gt: "gt", challenge: "challenge", token: "token")
        let credentials = PersistedSessionDTO(accessToken: "token", refreshToken: "", mid: 42,
                                             expiresAtSecs: 0, webCookies: [])
        let vm = LoginViewModel(services: services { action, request in
            XCTAssertEqual(action, .password)
            requests.append(request)
            return requests.count == 1 ? .captcha(challenge) : .confirmed(credentials)
        })
        vm.select(.password)
        vm.username = "first@example.com"
        vm.password = " original password "
        vm.submit()
        await settle(vm)
        XCTAssertNotNil(vm.captcha)
        vm.username = "different@example.com"
        vm.password = "different"
        vm.completeCaptcha(LoginCaptchaProof(challenge: "challenge", validate: "proof", seccode: "sec", token: "token"), presentationID: vm.captcha!.id)
        vm.captchaDidDismiss(presentationID: vm.captcha?.id)
        await settle(vm)
        XCTAssertEqual(requests[1].username, "first@example.com")
        XCTAssertEqual(requests[1].password, " original password ")
        XCTAssertEqual(requests[1].captcha?.validate, "proof")
        XCTAssertEqual(vm.state, .success)
        XCTAssertTrue(vm.password.isEmpty)
    }

    @MainActor
    func testSmsCaptchaRetriesOriginalPhoneWithCompleteProofAndReceivesTicket() async throws {
        var requests: [LoginRequestDTO] = []
        var actions: [LoginAction] = []
        let vm = LoginViewModel(services: services { action, request in
            actions.append(action)
            requests.append(request)
            if requests.count == 1 {
                return .captcha(.init(gt: "sms-gt", challenge: "server-challenge", token: "sms-token+original"))
            }
            return .smsSent("sms-ticket")
        })
        vm.select(.sms)
        vm.phone = "13800000000"
        vm.sendSMS()
        await settle(vm)
        let id = try XCTUnwrap(vm.captcha?.id)
        vm.phone = "13900000000"
        vm.countryCode = "1"
        // Geetest may extend the challenge; submit its result, not the initial value.
        vm.completeCaptcha(.init(challenge: "widget-challenge", validate: "validate", seccode: "validate|jordan",
                                 token: "sms-token+original"), presentationID: id)
        vm.captchaDidDismiss(presentationID: id)
        await settle(vm)
        XCTAssertEqual(actions, [.sendSMS, .sendSMS])
        let encoded = try JSONEncoder().encode(requests[1])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["tel"] as? String, "13800000000")
        XCTAssertEqual(json["country_code"] as? String, "86")
        XCTAssertEqual(json["captcha"] as? [String: String], [
            "challenge": "widget-challenge", "validate": "validate", "seccode": "validate|jordan", "token": "sms-token+original"
        ])
        XCTAssertNil(vm.captcha)
        XCTAssertFalse(vm.isCaptchaPresented)
        XCTAssertEqual(vm.message, "短信验证码已发送")
        XCTAssertGreaterThan(vm.smsCooldownRemaining(at: Date()), 0)
        vm.phone = "13800000000"
        vm.countryCode = "86"
        vm.smsCode = "123456"
        vm.submit()
        await settle(vm)
        XCTAssertEqual(actions.last, .sms)
        XCTAssertEqual(requests.last?.captcha_key, "sms-ticket")
    }

    @MainActor
    func testSmsTicketCannotBeUsedForDifferentPhone() async {
        var calls = 0
        let vm = LoginViewModel(services: services { action, _ in
            calls += 1
            XCTAssertEqual(action, .sendSMS)
            return .smsSent("key")
        })
        vm.select(.sms)
        vm.phone = "13800000000"
        vm.sendSMS()
        await settle(vm)
        vm.phone = "13900000000"
        vm.smsCode = "123456"
        vm.submit()
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(vm.message)
        XCTAssertGreaterThan(vm.smsCooldownRemaining(at: Date()), 0)
        XCTAssertEqual(vm.smsCooldownRemaining(at: Date().addingTimeInterval(61)), 0)
    }

    @MainActor
    func testCancelledLoginCannotCommitLateCredentials() async {
        let entered = expectation(description: "request started")
        let returned = expectation(description: "request returned")
        var continuation: CheckedContinuation<LoginResultDTO, Never>?
        let vm = LoginViewModel(services: services { _, _ in
            let result = await withCheckedContinuation { continuation = $0; entered.fulfill() }
            returned.fulfill()
            return result
        })
        vm.select(.cookie)
        vm.cookie = "SESSDATA=test"
        vm.submit()
        await fulfillment(of: [entered], timeout: 2)
        vm.select(.password)
        continuation?.resume(returning: .confirmed(PersistedSessionDTO(
            accessToken: "", refreshToken: "", mid: 42, expiresAtSecs: 0, webCookies: [])))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.method, .password)
        XCTAssertTrue(vm.cookie.isEmpty)
    }

    @MainActor
    func testSendingSmsKeepsTicketAndCooldownWhenTabChangeIsAttempted() async {
        let entered = expectation(description: "send started")
        var continuation: CheckedContinuation<LoginResultDTO, Never>?
        let vm = LoginViewModel(services: services { _, _ in
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        })
        vm.select(.sms)
        vm.phone = "13800000000"
        vm.sendSMS()
        await fulfillment(of: [entered], timeout: 2)
        vm.select(.password)
        XCTAssertEqual(vm.method, .sms)
        XCTAssertTrue(vm.isSendingSMS)
        continuation?.resume(returning: .smsSent("ticket"))
        await settle(vm)
        XCTAssertFalse(vm.isSendingSMS)
        XCTAssertGreaterThan(vm.smsCooldownRemaining(at: Date()), 0)
        vm.select(.password)
        vm.select(.sms)
        XCTAssertGreaterThan(vm.smsCooldownRemaining(at: Date()), 0)
    }

    @MainActor
    func testLateQRCodeCannotRestartPollingAfterLeavingTab() async {
        let entered = expectation(description: "QR started")
        let returned = expectation(description: "QR returned")
        var continuation: CheckedContinuation<TvQrStartDTO, Never>?
        let vm = LoginViewModel(services: .init(qrStart: {
            let result = await withCheckedContinuation { continuation = $0; entered.fulfill() }
            returned.fulfill()
            return result
        }, qrPoll: { _ in XCTFail("stale QR must not poll"); return .pending }, submit: { _, _ in .smsSent("") }))
        vm.start()
        await fulfillment(of: [entered], timeout: 2)
        vm.select(.sms)
        continuation?.resume(returning: TvQrStartDTO(authCode: "test", url: "https://example.invalid"))
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.method, .sms)
    }

    @MainActor
    func testRiskSmsWaitsForUserCaptchaAndUsesRiskContext() async {
        let risk = LoginPhoneRisk(url: "https://passport.bilibili.com/risk", tmp_code: "tmp",
                                  request_id: "request", source: "risk", phone: "138****0000")
        var actions: [LoginAction] = []
        let vm = LoginViewModel(services: services { action, request in
            actions.append(action)
            switch action {
            case .password: return .phoneVerification(risk)
            case .captcha: return .captcha(.init(gt: "gt", challenge: "challenge", token: "token"))
            case .riskSend:
                XCTAssertEqual(request.risk?.tmp_code, "tmp")
                XCTAssertEqual(request.captcha?.validate, "proof")
                return .smsSent("risk-sms-key")
            default: XCTFail("unexpected action"); return .smsSent("")
            }
        })
        vm.select(.password)
        vm.username = "user"
        vm.password = "pass"
        vm.submit()
        await settle(vm)
        XCTAssertNotNil(vm.phoneRisk)
        vm.sendRiskSMS()
        await settle(vm)
        XCTAssertEqual(actions, [.password, .captcha])
        vm.completeCaptcha(.init(challenge: "challenge", validate: "proof", seccode: "sec", token: "token"), presentationID: vm.captcha!.id)
        vm.captchaDidDismiss(presentationID: vm.captcha?.id)
        await settle(vm)
        XCTAssertEqual(actions, [.password, .captcha, .riskSend])
        XCTAssertGreaterThan(vm.riskCooldownRemaining(at: Date()), 0)
    }
}
