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
    /// http(s) link's host before the app is asked). Links in shadow roots
    /// count too: the click is read through `composedPath()`, every new root
    /// (closed too) gets the same listener, and `click()` / `dispatchEvent`
    /// find the link from the element they are called on, which also reaches
    /// declarative closed roots the page clicks into.
    nonisolated static let meshGuardScript = #"""
    (function () {
      var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel',
                   'RTCIceCandidate', 'RTCSessionDescription', 'RTCRtpSender',
                   'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCIceTransport', 'RTCDtlsTransport'];
      function onMesh() {
        try { return window.top.location.protocol === 'nvfips:'; } catch (e) { return location.protocol === 'nvfips:'; }
      }
      if (!onMesh()) return;
      function lock(o, n, v) {
        try { Object.defineProperty(o, n, { value: v, writable: false, configurable: false }); } catch (e) {}
      }
      // Wrapped methods stay replaceable (polyfills patch them); the native
      // ones live only in this closure, so a replacement still runs ours.
      function wrap(o, n, v) {
        Object.defineProperty(o, n, { value: v, writable: true, enumerable: true, configurable: true });
      }
      function isLink(n) {
        return n && n.nodeType === 1 && n.hasAttribute && n.hasAttribute('href') &&
          /^(a|area)$/i.test(n.localName);
      }
      function linkURL(a) {
        var h = a.href;
        if (h && typeof h === 'object') h = h.baseVal; // SVG <a>
        try { return new URL(h, document.baseURI).href; } catch (e) { return ''; }
      }
      // Turns an http(s) link into nvleave: until this click is done.
      function leave(a) {
        if (!isLink(a)) return;
        var url = linkURL(a);
        if (!/^https?:/i.test(url)) return;
        var href = a.getAttribute('href');
        a.setAttribute('href', 'nvleave:' + encodeURIComponent(url));
        setTimeout(function () { a.setAttribute('href', href); }, 0);
      }
      // The link a click on n activates: n or its nearest flat-tree ancestor.
      function linkFrom(n) {
        for (var i = 0; n && i < 512; i++) {
          if (isLink(n)) return n;
          n = n.assignedSlot || n.parentNode || (n.host && n.nodeType === 11 ? n.host : null);
        }
        return null;
      }
      function onClick(e) {
        var path = e.composedPath ? e.composedPath() : [e.target];
        for (var i = 0; i < path.length; i++) if (isLink(path[i])) { leave(path[i]); return; }
      }
      function guard(w) {
        if (!w || w.__nvMeshGuard) return;
        lock(w, '__nvMeshGuard', true);
        names.forEach(function (n) { lock(w, n, undefined); });
        try {
          w.addEventListener('click', onClick, true);
          var E = w.Element.prototype, H = w.HTMLElement.prototype, T = w.EventTarget.prototype;
          var attach = E.attachShadow, click = H.click, dispatch = T.dispatchEvent;
          wrap(E, 'attachShadow', function () {
            var root = attach.apply(this, arguments);
            root.addEventListener('click', onClick, true);
            return root;
          });
          wrap(H, 'click', function () { leave(linkFrom(this)); return click.apply(this, arguments); });
          wrap(T, 'dispatchEvent', function (ev) {
            if (ev && ev.type === 'click' && this && this.nodeType) leave(linkFrom(this));
            return dispatch.apply(this, arguments);
          });
          // A frame the page makes itself (about:blank) gets its own copies.
          [w.HTMLIFrameElement, w.HTMLFrameElement, w.HTMLObjectElement].forEach(function (K) {
            var d = K && Object.getOwnPropertyDescriptor(K.prototype, 'contentWindow');
            if (!d || !d.get) return;
            Object.defineProperty(K.prototype, 'contentWindow', { configurable: false, get: function () {
              var f = d.get.call(this); if (f) try { guard(f); } catch (e) {} return f;
            } });
          });
        } catch (e) {}
      }
      guard(window);
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
