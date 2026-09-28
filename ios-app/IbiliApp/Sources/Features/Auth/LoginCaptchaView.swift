import SwiftUI
import WebKit

/// Only the verification widget is web content; credentials remain in the native form.
struct LoginCaptchaView: View {
    let challenge: LoginCaptchaChallenge
    let onSuccess: (LoginCaptchaProof) -> Void
    let onCancel: () -> Void
    @State private var errorMessage: String?
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("请完成哔哩哔哩要求的人机验证")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                    Button("重新加载") { self.errorMessage = nil; reloadID += 1 }
                }
                CaptchaWebView(challenge: challenge, onSuccess: onSuccess,
                               onError: { errorMessage = $0 }, onCancel: onCancel)
                    .id(reloadID)
            }
            .navigationTitle("安全验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
            }
        }
        .tint(IbiliTheme.accent)
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let challenge: LoginCaptchaChallenge
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
        webView.loadHTMLString(html, baseURL: URL(string: "https://passport.bilibili.com/"))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.finished = true
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "captcha")
    }

    private var html: String {
        // JSON encoding also escapes script terminators from remote parameters.
        let parameters = ["gt": challenge.gt, "challenge": challenge.challenge]
        let encoded = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data("{}".utf8)
        let json = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"></head>
        <body><script>
        const p = \(json);
        const report = (event, data) => window.webkit.messageHandlers.captcha.postMessage({event, data});
        let C, S, widget;
        function start() {
          if (C && S && !widget) {
            widget = Geetest(C).onSuccess(() => report('success', widget.getValidate()))
              .onError(() => report('error', '验证组件加载失败，请重新加载'))
              .onClose(() => report('close', null));
            widget.onReady(() => widget.verify());
          }
        }
        function geetestConfig(d) {
          if (!d || d.status !== 'success') { report('error','无法获取验证配置'); return; }
          C = Object.assign({gt:p.gt,challenge:p.challenge,offline:false,new_captcha:true,
            product:'bind',width:'100%',https:true,protocol:'https://'}, d.data); start();
        }
        function failed() { report('error','无法连接人机验证服务，请检查网络'); }
        const script = document.createElement('script');
        script.src = 'https://static.geetest.com/static/js/fullpage.0.0.0.js';
        script.onload = () => { S = true; start(); }; script.onerror = failed; document.head.appendChild(script);
        const config = document.createElement('script');
        config.src = 'https://api.geetest.com/gettype.php?gt=' + encodeURIComponent(p.gt) + '&callback=geetestConfig';
        config.onerror = failed; document.head.appendChild(config);
        </script></body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let parent: CaptchaWebView
        var finished = false
        init(parent: CaptchaWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !finished, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
            switch event {
            case "success":
                guard let data = body["data"] as? [String: String],
                      let challenge = data["geetest_challenge"], !challenge.isEmpty,
                      let validate = data["geetest_validate"], !validate.isEmpty,
                      let seccode = data["geetest_seccode"], !seccode.isEmpty else {
                    parent.onError("验证结果不完整，请重新加载"); return
                }
                finished = true
                parent.onSuccess(LoginCaptchaProof(challenge: challenge, validate: validate, seccode: seccode,
                                                   token: parent.challenge.token))
            case "close": finished = true; parent.onCancel()
            case "error": parent.onError(body["data"] as? String ?? "人机验证失败")
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let host = url.host ?? ""
            let allowed = url.absoluteString == "about:blank" || (url.scheme == "https" &&
                (host == "passport.bilibili.com" || ["geetest.com", "geevisit.com", "geetest.cn"].contains {
                    host == $0 || host.hasSuffix("." + $0)
                }))
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !finished else { return }
            parent.onError("无法加载人机验证，请检查网络后重试")
        }
    }
}
