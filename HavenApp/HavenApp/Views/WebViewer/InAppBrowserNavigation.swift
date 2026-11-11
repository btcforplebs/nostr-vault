import Foundation
import WebKit

/// The in-app browser's rules for where a page may go.
///
/// - `nvfips://` (mesh pages) and http(s) load in the view.
/// - A `.fips` URL never reaches the network: a top-level one is turned into
///   its `nvfips://` page, and every subresource one is blocked by a content
///   rule, because WKWebView does not pass through URLProtocol, so
///   `FipsHostBlocker` can't stop it. A small script then rewrites absolute
///   `http://<npub>.fips/…` links and media in the page onto the mesh.
/// - Any other scheme (`nostr:`, `lightning:`, `mailto:`…) is handed back to
///   the app, which routes it as a tap anywhere else would.
@MainActor
final class InAppBrowserNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// A link this view does not open (another scheme).
    var onExternal: ((URL) -> Void)?
    /// A top-level load failed before a page came (https errors).
    var onFailure: ((Error) -> Void)?

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let isMain = action.targetFrame?.isMainFrame ?? true
        switch FipsURL.navigation(to: url, isMainFrame: isMain) {
        case .allow:
            decisionHandler(.allow)
        case .load(let viewer):
            decisionHandler(.cancel)
            webView.load(URLRequest(url: viewer))
        case .refuse:
            decisionHandler(.cancel)
            if isMain { webView.loadHTMLString(FipsSchemeHandler.page(.refused, url: url), baseURL: nil) }
        case .external:
            decisionHandler(.cancel)
            // Only what the reader tapped: a page can't fire app links by itself.
            if action.navigationType == .linkActivated { onExternal?(url) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled { return }
        // WebKit's own "frame load interrupted" when a policy cancelled it.
        if (error as NSError).domain == "WebKitErrorDomain", (error as NSError).code == 102 { return }
        onFailure?(error)
    }

    // MARK: New windows

    /// `target=_blank` and `window.open` load here: one page at a time.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, action.targetFrame == nil {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - Rules installed in every browser

    /// Blocks every http(s)/ws(s) load to a `.fips` host before it leaves
    /// the device. WebKit content rules allow only a small regex subset (no
    /// `|` or `{}`), so each host shape is its own trigger.
    nonisolated static let fipsBlockRules: String = {
        let filters = [
            #"^https?://[^/]*\.fips[:/]"#, #"^https?://[^/]*\.fips$"#, #"^https?://[^/]*\.fips\.[:/]"#,
            #"^wss?://[^/]*\.fips[:/]"#, #"^wss?://[^/]*\.fips$"#,
        ]
        let rules = filters.map { filter -> [String: Any] in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }()

    static func compileBlockRules() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "nv-fips-block-v1", encodedContentRuleList: fipsBlockRules
            ) { list, error in
                if let error { print("InAppBrowser: content rules failed: \(error)") }
                continuation.resume(returning: list)
            }
        }
    }

    /// Rewrites absolute `http(s)://<npub>.fips/…` URLs in `href`, `src` and
    /// `poster` onto `nvfips://`, now and as the page adds nodes. The blocked
    /// first try costs nothing: the rule stops it before it leaves.
    nonisolated static let rewriteScript = #"""
    (function () {
      var re = /^https?:\/\/(npub1[02-9ac-hj-np-z]{58})\.fips\.?(?::80)?(\/|\?|#|$)/i;
      function fix(el) {
        ['href', 'src', 'poster'].forEach(function (a) {
          var v = el.getAttribute && el.getAttribute(a);
          if (!v) return;
          var m = v.match(re);
          if (m) el.setAttribute(a, 'nvfips://' + m[1].toLowerCase() + '/' + v.slice(m[0].length - m[2].length).replace(/^\//, ''));
        });
      }
      function walk(root) {
        if (root.nodeType !== 1) return;
        fix(root);
        root.querySelectorAll('[href],[src],[poster]').forEach(fix);
      }
      walk(document.documentElement);
      new MutationObserver(function (list) {
        list.forEach(function (m) {
          if (m.type === 'attributes') fix(m.target); else m.addedNodes.forEach(walk);
        });
      }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['href', 'src', 'poster'] });
    })();
    """#
}
