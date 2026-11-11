package com.nostrvault.ui.screens.browser

/**
 * Runs first in every page and frame of the in-app browser (WebViewCompat.addDocumentStartJavaScript), for what
 * neither `shouldInterceptRequest` nor the mesh page's policy can see (iOS: InAppBrowserNavigation.meshGuardScript).
 *
 * - Every page: a websocket to a `.fips` host is refused before it is opened. WebView never intercepts sockets,
 *   so `ws://<npub>.fips` would send the npub to DNS.
 * - Mesh pages (`*.fips`): WebRTC is taken away (a peer connection's STUN would show the site this device's IP),
 *   and a click on an http(s) link becomes an `nvleave:` link before the WebView acts on it, so leaving the mesh
 *   is asked about natively first. Links in shadow roots count too: the click is read through `composedPath()`,
 *   every new root (closed too) gets the same listener, and `click()` / `dispatchEvent` find the link from the
 *   element they are called on.
 * - Frames on a mesh page: WebView does not run this script in a frame's first `about:blank` document, and the
 *   page reaches that window without asking (`frames[0]`, `window[0]`, `contentDocument.defaultView`), so the
 *   parent guards it itself before any of the page's code can. Chromium fires an `about:blank` frame's `load`
 *   synchronously while the frame is being inserted, whatever DOM call inserted it; a capturing listener on the
 *   document (a load event never reaches the window) and on every shadow root takes the guard into the new window
 *   then. `contentWindow` / `contentDocument`, `setHTMLUnsafe` and a mutation observer sweep `window[i]` as a
 *   second line. A frame that can't read its parents (sandboxed, opaque origin) is a mesh frame when any
 *   `ancestorOrigins` entry is a `.fips` origin or opaque.
 * - What the guard needs from the page's world is copied before the page runs, so a page that replaces
 *   `Object.defineProperty` or `Event.prototype.target` does not switch the guard off for its next frame.
 */
internal object MeshGuardScript {
    const val SOURCE = """
(function () {
  var def = Object.defineProperty, desc = Object.getOwnPropertyDescriptor, apply = Reflect.apply;
  var listen = EventTarget.prototype.addEventListener;
  var targetOf = desc(Event.prototype, 'target').get, typeOf = desc(Event.prototype, 'type').get;
  var seen = new WeakSet(), has = WeakSet.prototype.has, add = WeakSet.prototype.add;
  var lower = String.prototype.toLowerCase, test = RegExp.prototype.test, trailingDot = /\.$/, fipsEnd = /\.fips$/;
  var strReplace = String.prototype.replace;
  function isFipsHost(h) {
    h = apply(strReplace, apply(lower, String(h || ''), []), [trailingDot, '']);
    return h === 'fips' || apply(test, fipsEnd, [h]);
  }
  function hostOf(w, url) { try { return new w.URL(url).hostname; } catch (e) { return ''; } }
  function guardSockets(w) {
    try {
      var WS = w.WebSocket;
      if (!WS || WS.__nvFips) return;
      var Safe = function (url, protocols) {
        var u; try { u = new w.URL(url, w.document.baseURI); } catch (e) { u = null; }
        if (u && isFipsHost(u.hostname)) throw new w.DOMException('A .fips socket never goes to DNS', 'SecurityError');
        return arguments.length > 1 ? new WS(url, protocols) : new WS(url);
      };
      Safe.prototype = WS.prototype;
      var k = ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'];
      for (var i = 0; i < k.length; i++) Safe[k[i]] = WS[k[i]];
      def(Safe, '__nvFips', { value: true });
      def(w, 'WebSocket', { value: Safe, writable: false, configurable: false });
    } catch (e) {}
  }
  var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCIceCandidate',
               'RTCSessionDescription', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver',
               'RTCIceTransport', 'RTCDtlsTransport'];
  /** A mesh frame, or one that can't tell: only a frame known to be on the web keeps WebRTC. */
  function onMesh(w) {
    var own = '';
    try { own = w.location.href; } catch (e) {}
    if (/^https?:/i.test(own)) return isFipsHost(hostOf(w, own));
    try { return isFipsHost(w.top.location.hostname); } catch (e) {}
    try {
      var a = w.location.ancestorOrigins;
      if (!a || !a.length) return true;
      for (var i = 0; i < a.length; i++) { var h = hostOf(w, a[i]); if (!h || isFipsHost(h)) return true; }
      return false;
    } catch (e) { return true; }
  }
  function lock(o, n, v) {
    try { def(o, n, { value: v, writable: false, configurable: false }); } catch (e) {}
  }
  function wrap(o, n, v) {
    def(o, n, { value: v, writable: true, enumerable: true, configurable: true });
  }
  function isLink(n) {
    return n && n.nodeType === 1 && n.hasAttribute && n.hasAttribute('href') && /^(a|area)$/i.test(n.localName);
  }
  function linkURL(a) {
    var h = a.href;
    if (h && typeof h === 'object') h = h.baseVal;
    try { return new URL(h, document.baseURI).href; } catch (e) { return ''; }
  }
  function leave(a) {
    if (!isLink(a)) return;
    var url = linkURL(a);
    if (!/^https?:/i.test(url)) return;
    try { if (isFipsHost(new URL(url).hostname)) return; } catch (e) { return; }
    var href = a.getAttribute('href');
    a.setAttribute('href', 'nvleave:' + encodeURIComponent(url));
    setTimeout(function () { a.setAttribute('href', href); }, 0);
  }
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
  // Getters for a frame element's window, copied before the page runs.
  var frameWindow = [];
  [window.HTMLIFrameElement, window.HTMLFrameElement, window.HTMLObjectElement].forEach(function (K) {
    var d = K && desc(K.prototype, 'contentWindow');
    if (d && d.get) frameWindow.push(d.get);
  });
  function windowOf(el) {
    for (var i = 0; i < frameWindow.length; i++) { try { var f = apply(frameWindow[i], el, []); if (f) return f; } catch (e) {} }
    return null;
  }
  /** Every child window of [w] the page could reach by index. */
  function sweep(w) {
    for (var i = 0; i < 1000; i++) {
      var f; try { f = w[i]; } catch (e) { break; }
      if (!f) break;
      guard(f, true);
    }
  }
  /** An about:blank frame's load runs while it is inserted: guard the new window before the inserting call returns. */
  function onLoad(e) {
    var t; try { t = apply(targetOf, e, []); } catch (x) { return; }
    var f = t ? windowOf(t) : null;
    if (f) guard(f, true);
  }
  function watchFrames(root) { try { apply(listen, root, ['load', onLoad, true]); } catch (e) {} }
  function guard(w, mesh) {
    // Keyed on the document: a frame that navigates keeps its window object but gets a new world to guard.
    var doc; try { doc = w.document; } catch (e) { return; }
    try { if (!doc || apply(has, seen, [doc])) return; apply(add, seen, [doc]); } catch (e) { return; }
    guardSockets(w);
    if (!mesh && !onMesh(w)) return;
    for (var i = 0; i < names.length; i++) lock(w, names[i], undefined);
    // A load event stops at the document: it never reaches the window.
    watchFrames(doc);
    sweep(w);
    try {
      apply(listen, w, ['click', onClick, true]);
      var E = w.Element.prototype, H = w.HTMLElement.prototype, T = w.EventTarget.prototype;
      var attach = E.attachShadow, click = H.click, dispatch = T.dispatchEvent;
      wrap(E, 'attachShadow', function () {
        var root = apply(attach, this, arguments);
        apply(listen, root, ['click', onClick, true]);
        watchFrames(root);
        return root;
      });
      wrap(H, 'click', function () { leave(linkFrom(this)); return apply(click, this, arguments); });
      wrap(T, 'dispatchEvent', function (ev) {
        if (ev && ev.type === 'click' && this && this.nodeType) leave(linkFrom(this));
        return apply(dispatch, this, arguments);
      });
      // Second line: the page asked for a frame's window or document, or parsed HTML that may hold frames.
      [w.HTMLIFrameElement, w.HTMLFrameElement, w.HTMLObjectElement].forEach(function (K) {
        if (!K) return;
        ['contentWindow', 'contentDocument'].forEach(function (n) {
          var d = desc(K.prototype, n);
          if (!d || !d.get) return;
          def(K.prototype, n, { configurable: false, enumerable: true, get: function () {
            var f = windowOf(this); if (f) guard(f, true);
            return apply(d.get, this, []);
          } });
        });
      });
      [w.Element && w.Element.prototype, w.ShadowRoot && w.ShadowRoot.prototype].forEach(function (P) {
        var html = P && P.setHTMLUnsafe;
        if (html) wrap(P, 'setHTMLUnsafe', function () { var r = apply(html, this, arguments); sweep(w); return r; });
      });
      new w.MutationObserver(function () { sweep(w); }).observe(w.document, { childList: true, subtree: true });
    } catch (e) {}
  }
  guard(window, false);
})();
"""
}
