import Foundation

/// Shared by the WKWebView and bootstrap regression tests.
enum LoginCaptchaPage {
    static func html(challenge: LoginCaptchaChallenge) -> String {
        let parameters = ["gt": challenge.gt, "challenge": challenge.challenge]
        let encoded = try! JSONSerialization.data(withJSONObject: parameters)
        let json = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:transparent}</style>
        </head><body><script>
        (() => {
          const parameters = \(json);
          const report = (event, data) => window.webkit.messageHandlers.captcha.postMessage({event, data});
          let configuration, scriptLoaded = false, widget, finished = false;
          const fail = stage => {
            if (finished) return;
            finished = true;
            report('error', stage);
          };
          window.addEventListener('error', () => fail('script'));
          window.addEventListener('unhandledrejection', () => fail('script'));
          function start() {
            if (!configuration || !scriptLoaded || widget || finished) return;
            try {
              widget = Geetest(configuration)
                .onSuccess(() => {
                  if (finished) return;
                  const proof = widget.getValidate();
                  if (!proof || !proof.geetest_challenge || !proof.geetest_validate || !proof.geetest_seccode) {
                    fail('proof'); return;
                  }
                  finished = true;
                  report('success', proof);
                })
                .onError(() => fail('widget'))
                .onClose(() => {
                  if (finished) return;
                  finished = true; report('close', null);
                });
              widget.onReady(() => {
                if (finished) return;
                report('ready', null);
                widget.verify();
              });
            } catch (_) { fail('initialization'); }
          }
          // Geetest rejects arbitrary JSONP callback names with error_05 (jsonp xss).
          // Keep the same geetest_<milliseconds> contract as PiliPlus.
          const callback = 'geetest_' + Date.now();
          window[callback] = response => {
            if (finished) return;
            if (!response || response.status !== 'success') { fail('configuration'); return; }
            configuration = Object.assign({gt:parameters.gt,challenge:parameters.challenge,
              offline:false,new_captcha:true,product:'bind',width:'100%',https:true,protocol:'https://'}, response.data);
            start();
          };
          const script = document.createElement('script');
          script.src = 'https://static.geetest.com/static/js/fullpage.0.0.0.js';
          script.onload = () => { scriptLoaded = true; start(); };
          script.onerror = () => fail('network');
          document.head.appendChild(script);
          const config = document.createElement('script');
          config.src = 'https://api.geetest.com/gettype.php?gt=' + encodeURIComponent(parameters.gt) + '&callback=' + callback;
          config.onerror = () => fail('network');
          document.head.appendChild(config);
        })();
        </script></body></html>
        """
    }

    static func allowsNavigation(to url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "passport.bilibili.com" || ["geetest.com", "geevisit.com", "geetest.cn"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
}
