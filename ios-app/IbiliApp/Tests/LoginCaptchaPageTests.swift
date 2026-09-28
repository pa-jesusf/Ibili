import XCTest
import JavaScriptCore
@testable import Ibili

final class LoginCaptchaPageTests: XCTestCase {
    private func context(challenge: String = "challenge") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail(exception?.toString() ?? "JavaScript error") }
        context.evaluateScript("""
        var window = this, events = [], scripts = [], listeners = {}, verified = false, handlers = {};
        window.webkit = {messageHandlers:{captcha:{postMessage: value => events.push(value)}}};
        window.addEventListener = (name, handler) => listeners[name] = handler;
        var document = {createElement: () => ({}), head: {appendChild: script => scripts.push(script)}};
        var fakeWidget = {
          onSuccess(handler) { handlers.success = handler; return this; },
          onError(handler) { handlers.error = handler; return this; },
          onClose(handler) { handlers.close = handler; return this; },
          onReady(handler) { handlers.ready = handler; return this; },
          verify() { verified = true; },
          getValidate() { return {geetest_challenge:'challenge',geetest_validate:'proof',geetest_seccode:'sec'}; }
        };
        function Geetest(config) { window.receivedConfig = config; return fakeWidget; }
        """)
        let html = LoginCaptchaPage.html(challenge: .init(gt: "gt", challenge: challenge, token: "token"))
        let start = try XCTUnwrap(html.range(of: "<script>"))
        let end = try XCTUnwrap(html.range(of: "</script>"))
        context.evaluateScript(String(html[start.upperBound..<end.lowerBound]))
        return context
    }

    private func configure(_ context: JSContext) {
        context.evaluateScript("""
        var callbackName = scripts[1].src.split('callback=')[1];
        window[callbackName]({status:'success',data:{}});
        """)
    }

    func testJSONPCallbackMatchesGeetestContractAndStartsInEitherLoadOrder() throws {
        for configFirst in [true, false] {
            let context = try context()
            let url = try XCTUnwrap(context.evaluateScript("scripts[1].src")?.toString())
            let query = try XCTUnwrap(URLComponents(string: url)?.queryItems)
            let callback = try XCTUnwrap(query.first(where: { $0.name == "callback" })?.value)
            XCTAssertNotNil(callback.range(of: "^geetest_[0-9]+$", options: .regularExpression))
            if configFirst {
                configure(context)
                context.evaluateScript("scripts[0].onload()")
            } else {
                context.evaluateScript("scripts[0].onload()")
                configure(context)
            }
            context.evaluateScript("handlers.ready()")
            XCTAssertEqual(context.evaluateScript("events[0].event")?.toString(), "ready")
            XCTAssertEqual(context.evaluateScript("verified")?.toBool(), true)
            context.evaluateScript("handlers.success(); handlers.close(); handlers.success()")
            XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 2)
            XCTAssertEqual(context.evaluateScript("events[1].event")?.toString(), "success")
        }
    }

    func testScriptAndConfigurationFailuresReachNativeInsteadOfStayingBlank() throws {
        for failure in ["scripts[0].onerror()", "listeners.error()", "listeners.unhandledrejection()",
                        "window[scripts[1].src.split('callback=')[1]]({status:'error'})"] {
            let context = try context()
            context.evaluateScript(failure)
            configure(context)
            context.evaluateScript("scripts[0].onload()")
            XCTAssertEqual(context.evaluateScript("events[0].event")?.toString(), "error")
            XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 1)
            XCTAssertEqual(context.evaluateScript("verified")?.toBool(), false)
        }
    }

    func testIncompleteProofCannotCompleteVerification() throws {
        let context = try context()
        configure(context)
        context.evaluateScript("scripts[0].onload(); fakeWidget.getValidate = () => ({}); handlers.success()")
        XCTAssertEqual(context.evaluateScript("events[0].event")?.toString(), "error")
        XCTAssertEqual(context.evaluateScript("events[0].data")?.toString(), "proof")
    }

    func testRemoteParametersCannotTerminateScriptAndNavigateElsewhere() throws {
        let value = "</script><script>throw new Error('injection')</script>"
        let context = try context(challenge: value)
        configure(context)
        context.evaluateScript("scripts[0].onload()")
        XCTAssertEqual(context.evaluateScript("receivedConfig.challenge")?.toString(), value)
        XCTAssertTrue(LoginCaptchaPage.allowsNavigation(to: URL(string: "https://api.geetest.com/verify")!))
        XCTAssertTrue(LoginCaptchaPage.allowsNavigation(to: URL(string: "about:blank")!))
        XCTAssertFalse(LoginCaptchaPage.allowsNavigation(to: URL(string: "https://geetest.com.evil.test")!))
        XCTAssertFalse(LoginCaptchaPage.allowsNavigation(to: URL(string: "http://geetest.com")!))
    }
}
