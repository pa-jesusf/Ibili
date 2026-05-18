import SwiftUI
import WebKit

struct AnimeCaptchaRequest: Identifiable {
    let sourceID: String
    let sourceName: String
    let url: URL

    var id: String { "\(sourceID)-\(url.absoluteString)" }
}

struct AnimeCaptchaWebViewSheet: View {
    let request: AnimeCaptchaRequest
    let onSolved: (AnimeCaptchaSessionDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var session: AnimeCaptchaSessionDTO?

    var body: some View {
        NavigationStack {
            AnimeCaptchaWebView(request: request, session: $session)
                .navigationTitle(request.sourceName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") {
                            if let session {
                                onSolved(session)
                            }
                            dismiss()
                        }
                        .disabled(session?.cookies.isEmpty != false && session?.html.isEmpty != false)
                    }
                }
        }
    }
}

private struct AnimeCaptchaWebView: UIViewRepresentable {
    let request: AnimeCaptchaRequest
    @Binding var session: AnimeCaptchaSessionDTO?

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request, session: $session)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = BiliHTTP.headers["User-Agent"]
        webView.load(URLRequest(url: request.url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let request: AnimeCaptchaRequest
        @Binding private var session: AnimeCaptchaSessionDTO?

        init(request: AnimeCaptchaRequest, session: Binding<AnimeCaptchaSessionDTO?>) {
            self.request = request
            _session = session
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            collectSession(from: webView)
        }

        private func collectSession(from webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                let html = value as? String ?? ""
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    let host = webView.url?.host ?? self.request.url.host ?? ""
                    let cookieText = cookies
                        .filter { cookie in
                            guard !host.isEmpty else { return true }
                            return host.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                        }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    let session = AnimeCaptchaSessionDTO(
                        sourceID: self.request.sourceID,
                        pageURL: self.request.url.absoluteString,
                        finalURL: webView.url?.absoluteString ?? self.request.url.absoluteString,
                        cookies: cookieText,
                        html: html,
                        captchaKind: ""
                    )
                    DispatchQueue.main.async {
                        self.session = session
                    }
                }
            }
        }
    }
}

struct AnimeWebVideoResolveRequest: Identifiable, Equatable {
    let id = UUID()
    let candidate: AnimeMediaCandidateDTO
    let title: String
    let cover: String

    var url: URL {
        URL(string: candidate.url) ?? URL(string: candidate.pageURL) ?? URL(string: "about:blank")!
    }
}

struct AnimeWebVideoResolveResult {
    let requestID: UUID
    let play: AnimePlayUrlDTO?
    let errorText: String?
    let method: String
}

struct AnimeWebVideoResolverHost: UIViewRepresentable {
    let request: AnimeWebVideoResolveRequest
    let onComplete: (AnimeWebVideoResolveResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(request: request, onComplete: onComplete)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(
            source: Self.snifferScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContent.add(context.coordinator, name: "ibiliMediaSniffer")
        configuration.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = context.coordinator.userAgent
        context.coordinator.webView = webView
        context.coordinator.startTimeout()
        webView.load(context.coordinator.urlRequest(for: request.url))
        AppLog.info("anime", "追番 WebView 嗅探 WebView 已创建", metadata: context.coordinator.logMetadata(extra: [
            "url": AnimePlayerViewModel.redactedURL(request.url.absoluteString),
        ]))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.request.id != request.id else { return }
        context.coordinator.cancel(reason: "request_changed")
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel(reason: "dismantle")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "ibiliMediaSniffer")
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let request: AnimeWebVideoResolveRequest
        let onComplete: (AnimeWebVideoResolveResult) -> Void
        let userAgent: String
        weak var webView: WKWebView?

        private var isCompleted = false
        private var timeoutTask: Task<Void, Never>?
        private var scanTask: Task<Void, Never>?
        private var seenURLs = Set<String>()

        init(request: AnimeWebVideoResolveRequest, onComplete: @escaping (AnimeWebVideoResolveResult) -> Void) {
            self.request = request
            self.onComplete = onComplete
            self.userAgent = request.candidate.userAgent.isEmpty ? BiliHTTP.headers["User-Agent"] ?? "" : request.candidate.userAgent
        }

        func urlRequest(for url: URL) -> URLRequest {
            var urlRequest = URLRequest(url: url)
            for (key, value) in request.candidate.headers where key.caseInsensitiveCompare("Cookie") != .orderedSame {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
            if !request.candidate.referer.isEmpty {
                urlRequest.setValue(request.candidate.referer, forHTTPHeaderField: "Referer")
            }
            urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            urlRequest.timeoutInterval = 18
            return urlRequest
        }

        func startTimeout() {
            timeoutTask?.cancel()
            scanTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 18_000_000_000)
                await MainActor.run {
                    self?.complete(play: nil, errorText: "WebView 嗅探超时", method: "timeout")
                }
            }
            scanTask = Task { [weak self] in
                for _ in 0..<36 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        self?.scanWebView(method: "periodic-scan")
                    }
                    if Task.isCancelled { return }
                }
            }
        }

        func cancel(reason: String) {
            timeoutTask?.cancel()
            scanTask?.cancel()
            timeoutTask = nil
            scanTask = nil
            if !isCompleted {
                AppLog.debug("anime", "追番 WebView 嗅探取消", metadata: logMetadata(extra: ["reason": reason]))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            AppLog.debug("anime", "追番 WebView 页面加载完成", metadata: logMetadata(extra: [
                "url": AnimePlayerViewModel.redactedURL(webView.url?.absoluteString ?? ""),
            ]))
            collectCookies(from: webView)
            scanWebView(method: "didFinish")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            AppLog.warning("anime", "追番 WebView 页面加载失败", metadata: logMetadata(extra: [
                "error": error.localizedDescription,
            ]))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            AppLog.warning("anime", "追番 WebView 初始加载失败", metadata: logMetadata(extra: [
                "error": error.localizedDescription,
            ]))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            inspect(url: navigationAction.request.url, method: "navigationAction")
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            inspect(url: navigationResponse.response.url, method: "navigationResponse")
            if let response = navigationResponse.response as? HTTPURLResponse {
                AppLog.debug("anime", "追番 WebView 响应", metadata: logMetadata(extra: [
                    "status": String(response.statusCode),
                    "url": AnimePlayerViewModel.redactedURL(response.url?.absoluteString ?? ""),
                    "mime": response.mimeType ?? "",
                ]))
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ibiliMediaSniffer" else { return }
            if let url = message.body as? String {
                inspect(urlString: url, method: "script-message")
                return
            }
            if let payload = message.body as? [String: Any],
               let url = payload["url"] as? String {
                inspect(urlString: url, method: payload["method"] as? String ?? "script-message")
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                AppLog.debug("anime", "追番 WebView 拦截新窗口", metadata: logMetadata(extra: [
                    "url": AnimePlayerViewModel.redactedURL(url.absoluteString),
                ]))
                webView.load(urlRequest(for: url))
            }
            return nil
        }

        func scanWebView(method: String) {
            guard let webView, !isCompleted else { return }
            webView.evaluateJavaScript(AnimeWebVideoResolverHost.scanScript) { [weak self] value, error in
                guard let self, !self.isCompleted else { return }
                if let error {
                    AppLog.debug("anime", "追番 WebView 扫描失败", metadata: self.logMetadata(extra: [
                        "method": method,
                        "error": error.localizedDescription,
                    ]))
                    return
                }
                let urls: [String]
                if let array = value as? [String] {
                    urls = array
                } else if let array = value as? [Any] {
                    urls = array.compactMap { $0 as? String }
                } else {
                    urls = []
                }
                AppLog.debug("anime", "追番 WebView 扫描完成", metadata: self.logMetadata(extra: [
                    "method": method,
                    "count": String(urls.count),
                ]))
                for url in urls {
                    self.inspect(urlString: url, method: method)
                }
            }
        }

        func inspect(url: URL?, method: String) {
            guard let url else { return }
            inspect(urlString: url.absoluteString, method: method)
        }

        func inspect(urlString: String, method: String) {
            guard !isCompleted, isMediaURL(urlString), seenURLs.insert(urlString).inserted else { return }
            AppLog.info("anime", "追番 WebView 捕获媒体候选", metadata: logMetadata(extra: [
                "method": method,
                "url": AnimePlayerViewModel.redactedURL(urlString),
                "format": mediaFormat(urlString),
            ]))
            collectCookies(from: webView) { [weak self] cookieHeader in
                guard let self else { return }
                var headers = self.request.candidate.headers
                headers["User-Agent"] = headers["User-Agent"] ?? self.userAgent
                if !self.request.candidate.referer.isEmpty {
                    headers["Referer"] = headers["Referer"] ?? self.request.candidate.referer
                } else if let pageURL = self.webView?.url?.absoluteString {
                    headers["Referer"] = headers["Referer"] ?? pageURL
                }
                headers["Accept"] = headers["Accept"] ?? "*/*"
                if !cookieHeader.isEmpty {
                    headers["Cookie"] = cookieHeader
                }
                let play = AnimePlayUrlDTO(
                    url: urlString,
                    format: self.mediaFormat(urlString),
                    title: self.request.title,
                    cover: self.request.cover,
                    referer: headers["Referer"] ?? "",
                    userAgent: headers["User-Agent"] ?? self.userAgent,
                    headers: headers,
                    durationMs: 0
                )
                self.complete(play: play, errorText: nil, method: method)
            }
        }

        func complete(play: AnimePlayUrlDTO?, errorText: String?, method: String) {
            guard !isCompleted else { return }
            isCompleted = true
            timeoutTask?.cancel()
            scanTask?.cancel()
            webView?.stopLoading()
            AppLog.info("anime", "追番 WebView 嗅探结束", metadata: logMetadata(extra: [
                "success": play == nil ? "false" : "true",
                "method": method,
                "error": errorText ?? "",
                "url": play.map { AnimePlayerViewModel.redactedURL($0.url) } ?? "",
            ]))
            onComplete(AnimeWebVideoResolveResult(
                requestID: request.id,
                play: play,
                errorText: errorText,
                method: method
            ))
        }

        func collectCookies(from webView: WKWebView?, completion: ((String) -> Void)? = nil) {
            guard let webView else {
                completion?("")
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host = webView.url?.host ?? self.request.url.host ?? ""
                let value = cookies
                    .filter { cookie in
                        guard !host.isEmpty else { return true }
                        return host.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                completion?(value)
            }
        }

        func logMetadata(extra: [String: String] = [:]) -> [String: String] {
            var metadata: [String: String] = [
                "requestID": request.id.uuidString,
                "sourceID": request.candidate.sourceID,
                "source": request.candidate.sourceName,
                "candidateURL": AnimePlayerViewModel.redactedURL(request.candidate.url),
            ]
            for (key, value) in extra {
                metadata[key] = value
            }
            return metadata
        }

        func isMediaURL(_ value: String) -> Bool {
            let lower = value.lowercased()
            return lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".m4v")
        }

        func mediaFormat(_ value: String) -> String {
            value.lowercased().contains(".m3u8") ? "hls" : "mp4"
        }
    }

    private static let snifferScript = """
    (() => {
      if (window.__ibiliMediaSnifferInstalled) return;
      window.__ibiliMediaSnifferInstalled = true;
      const isMedia = (value) => typeof value === 'string' && /\\.m3u8(?:\\?|$)|\\.mp4(?:\\?|$)|\\.m4v(?:\\?|$)/i.test(value);
      const post = (url, method) => {
        try {
          if (isMedia(url)) window.webkit.messageHandlers.ibiliMediaSniffer.postMessage({ url, method });
        } catch (_) {}
      };
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function(input, init) {
          const url = typeof input === 'string' ? input : (input && input.url);
          post(url, 'fetch');
          return originalFetch.apply(this, arguments).then((response) => {
            post(response && response.url, 'fetch-response');
            return response;
          });
        };
      }
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        post(url, 'xhr-open');
        this.addEventListener('load', function() { post(this.responseURL, 'xhr-load'); });
        return originalOpen.apply(this, arguments);
      };
      const originalSetAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function(name, value) {
        if (name === 'src' || name === 'href') post(value, 'setAttribute');
        return originalSetAttribute.apply(this, arguments);
      };
      const observer = new MutationObserver(() => {
        document.querySelectorAll('video[src], source[src], a[href]').forEach((node) => {
          post(node.currentSrc || node.src || node.href, 'mutation');
        });
      });
      observer.observe(document.documentElement || document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'href'] });
    })();
    """

    private static let scanScript = """
    (() => {
      const urls = new Set();
      const add = (value) => {
        if (typeof value === 'string' && /\\.m3u8(?:\\?|$)|\\.mp4(?:\\?|$)|\\.m4v(?:\\?|$)/i.test(value)) urls.add(value);
      };
      document.querySelectorAll('video, source, a').forEach((node) => {
        add(node.currentSrc);
        add(node.src);
        add(node.href);
      });
      try {
        performance.getEntriesByType('resource').forEach((entry) => add(entry.name));
      } catch (_) {}
      return Array.from(urls);
    })();
    """
}
