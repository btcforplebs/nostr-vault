import Foundation
import WebKit

/// The in-app browser's rules for where a page may go.
///
/// - `nvfips://` (mesh pages) and http(s) load in the view, but a mesh page
///   reaches no internet host by itself: its loads are blocked by a content
///   rule, and a link off the mesh is asked about natively first.
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
    /// The reader tapped a link from a mesh page to the internet: ask first.
    var onLeaveMesh: ((URL) -> Void)?
    /// The one internet page a mesh page may go to next: what the reader
    /// typed, or confirmed. Used once.
    var allowedOnce: URL?

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let isMain = action.targetFrame?.isMainFrame ?? true
        let fromMesh = webView.url?.scheme?.lowercased() == FipsURL.scheme
        switch FipsURL.navigation(to: url, isMainFrame: isMain, fromMesh: fromMesh) {
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
        case .leaveMesh(let target):
            if isMain, target == url, let allowed = allowedOnce, allowed == url {
                allowedOnce = nil
                return decisionHandler(.allow)
            }
            // Back/forward goes where the reader already was.
            if isMain, target == url, action.navigationType == .backForward { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            // A page can fake a link tap (`a.click()`), so even a tap only
            // asks, natively; script, refresh and redirect leaves are dropped.
            if action.navigationType == .linkActivated { onLeaveMesh?(target) }
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

    /// The content rules (`FipsURL.browserRulesJSON`): no `.fips` host ever
    /// reaches the network, and a mesh page reaches no internet host at all.
    nonisolated static var blockRules: String { FipsURL.browserRulesJSON }

    static func compileBlockRules() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "nv-fips-block-v2", encodedContentRuleList: blockRules
            ) { list, error in
                if let error { print("InAppBrowser: content rules failed: \(error)") }
                continuation.resume(returning: list)
            }
        }
    }

    /// Runs first in every mesh page and frame, for what content rules can't
    /// see: WebRTC is taken away (a peer connection's STUN would show the site
    /// this device's IP), and a click on an http(s) link becomes an
    /// `nvleave:` link before WebKit acts on it (WebKit connects to a clicked
    /// http(s) link's host before the app is asked).
    nonisolated static let meshGuardScript = #"""
    (function () {
      var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
                   'RTCIceCandidate', 'RTCSessionDescription', 'RTCRtpSender',
                   'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCIceTransport', 'RTCDtlsTransport'];
      function scrub(w) {
        names.forEach(function (n) {
          try { Object.defineProperty(w, n, { value: undefined, writable: false, configurable: false }); } catch (e) {}
        });
      }
      function onMesh() {
        try { return window.top.location.protocol === 'nvfips:'; } catch (e) { return location.protocol === 'nvfips:'; }
      }
      if (!onMesh()) return;
      scrub(window);
      window.addEventListener('click', function (e) {
        var a = e.target && e.target.closest && e.target.closest('a[href], area[href]');
        if (!a || !/^https?:/i.test(a.href)) return;
        var href = a.getAttribute('href');
        a.setAttribute('href', 'nvleave:' + encodeURIComponent(a.href));
        setTimeout(function () { a.setAttribute('href', href); }, 0);
      }, true);
      // A frame the page makes itself (about:blank) gets its own copies.
      [HTMLIFrameElement, HTMLFrameElement, HTMLObjectElement].forEach(function (K) {
        var d = K && Object.getOwnPropertyDescriptor(K.prototype, 'contentWindow');
        if (!d || !d.get) return;
        Object.defineProperty(K.prototype, 'contentWindow', { configurable: false, get: function () {
          var w = d.get.call(this); if (w) try { scrub(w); } catch (e) {} return w;
        } });
      });
    })();
    """#

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
