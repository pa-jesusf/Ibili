import SwiftUI
import WebKit

/// Only the verification widget is web content; credentials remain in the native form.
struct LoginCaptchaView: View {
    let challenge: LoginCaptchaChallenge
    let onSuccess: (LoginCaptchaProof) -> Void
    let onCancel: () -> Void
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var reloadID = 0

    var body: some View {
        SheetScaffold(title: "安全验证", showsDoneButton: false) {
            ZStack {
                CaptchaWebView(challenge: challenge, onReady: { isLoading = false }, onSuccess: onSuccess,
                               onError: { isLoading = false; errorMessage = $0 }, onCancel: onCancel)
                    .id(reloadID)
                if let errorMessage {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.shield")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
                        Text(errorMessage).multilineTextAlignment(.center)
                        Button("重新加载") {
                            self.errorMessage = nil
                            isLoading = true
                            reloadID += 1
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(IbiliTheme.background)
                } else if isLoading {
                    ProgressView("正在加载验证…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(IbiliTheme.background)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IbiliTheme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
            }
        }
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let challenge: LoginCaptchaChallenge
    let onReady: () -> Void
    let onSuccess: (LoginCaptchaProof) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "captcha")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.beginLoading(webView)
        webView.loadHTMLString(LoginCaptchaPage.html(challenge: challenge), baseURL: URL(string: "https://passport.bilibili.com/"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.finish()
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "captcha")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: CaptchaWebView
        private var finished = false
        private var loadingTimeout: DispatchWorkItem?
        private weak var webView: WKWebView?
        init(parent: CaptchaWebView) { self.parent = parent }

        func beginLoading(_ webView: WKWebView) {
            self.webView = webView
            let timeout = DispatchWorkItem { [weak self] in
                self?.fail("验证加载超时，请检查网络后重试", stage: "timeout")
            }
            loadingTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        }

        func finish() {
            finished = true
            loadingTimeout?.cancel()
            loadingTimeout = nil
        }

        private func fail(_ message: String, stage: String) {
            guard !finished else { return }
            finish()
            webView?.stopLoading()
            // No challenge, token, verification proof or remote response in diagnostics.
            AppLog.error("auth", "人机验证加载失败", metadata: ["stage": stage])
            parent.onError(message)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            switch event {
            case "ready":
                loadingTimeout?.cancel()
                loadingTimeout = nil
                parent.onReady()
            case "success":
                guard let data = body["data"] as? [String: String],
                      let challenge = data["geetest_challenge"], !challenge.isEmpty,
                      let validate = data["geetest_validate"], !validate.isEmpty,
                      let seccode = data["geetest_seccode"], !seccode.isEmpty else {
                    fail("验证结果不完整，请重新加载", stage: "proof"); return
                }
                finish()
                parent.onSuccess(LoginCaptchaProof(challenge: challenge, validate: validate, seccode: seccode,
                                                   token: parent.challenge.token))
            case "close": finish(); parent.onCancel()
            case "error":
                let knownStages = ["network", "configuration", "script", "widget", "proof", "initialization"]
                let stage = body["data"] as? String ?? "unknown"
                fail("无法加载安全验证，请重新加载", stage: knownStages.contains(stage) ? stage : "unknown")
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url.map(LoginCaptchaPage.allowsNavigation) == true ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail("无法连接验证服务，请检查网络后重试", stage: "navigation")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail("验证页面加载失败，请重试", stage: "navigation")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("验证页面已中断，请重新加载", stage: "web_content")
        }
    }
}
