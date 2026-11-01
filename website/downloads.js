// Download buttons and cards, the visitor's own device first. Each [data-downloads] list holds links marked
// data-device="ios" | "android" | "mac" | "web". The matching one moves to the front; on a phone the Mac button is
// hidden in the button rows (the Mac card in the download grid stays). Without JavaScript every link shows in page order.
(function () {
    'use strict';

    var ua = navigator.userAgent || '';
    // iPadOS asks for the desktop site and says "Macintosh"; a touch screen gives it away.
    var ipad = /Macintosh/.test(ua) && navigator.maxTouchPoints > 1;
    var device = /iPhone|iPad|iPod/.test(ua) || ipad ? 'ios'
        : /Android/.test(ua) ? 'android'
        : /Macintosh|Mac OS X/.test(ua) ? 'mac'
        : '';
    if (!device) return;
    var phone = device === 'ios' || device === 'android';

    document.querySelectorAll('[data-downloads]').forEach(function (list) {
        var own = list.querySelector('[data-device="' + device + '"]');
        if (own) list.insertBefore(own, list.firstElementChild);
        if (phone && list.classList.contains('hero-buttons')) {
            var mac = list.querySelector('[data-device="mac"]');
            if (mac) mac.style.display = 'none'; // .btn sets display, so [hidden] alone would not hide it
        }
    });
})();
