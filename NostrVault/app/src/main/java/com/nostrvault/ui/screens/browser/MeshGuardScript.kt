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
 *   element they are called on. Frames the page makes get the same guard via `contentWindow`.
 */
internal object MeshGuardScript {
    const val SOURCE = """
(function () {
  function isFipsHost(h) { h = String(h || '').toLowerCase().replace(/\.$/, ''); return h === 'fips' || /\.fips$/.test(h); }
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
      ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (k) { Safe[k] = WS[k]; });
      Object.defineProperty(Safe, '__nvFips', { value: true });
      Object.defineProperty(w, 'WebSocket', { value: Safe, writable: false, configurable: false });
    } catch (e) {}
  }
  var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCIceCandidate',
               'RTCSessionDescription', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver',
               'RTCIceTransport', 'RTCDtlsTransport'];
  function onMesh(w) {
    try { return isFipsHost(w.top.location.hostname); } catch (e) { return isFipsHost(w.location.hostname); }
  }
  function lock(o, n, v) {
    try { Object.defineProperty(o, n, { value: v, writable: false, configurable: false }); } catch (e) {}
  }
  function wrap(o, n, v) {
    Object.defineProperty(o, n, { value: v, writable: true, enumerable: true, configurable: true });
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
  function guard(w) {
    if (!w || w.__nvMeshGuard) return;
    lock(w, '__nvMeshGuard', true);
    guardSockets(w);
    if (!onMesh(w)) return;
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
"""
}
