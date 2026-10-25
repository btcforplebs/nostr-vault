// The site menu on phones and narrow windows (960px and under, where the header's links don't fit). One list for
// every page, so the home page, the docs, the blog and the privacy page all reach the same places as the desktop
// header and footer. Docs comes first. Without JavaScript the header's own Docs pill and the footer still work.
(function () {
    'use strict';

    var nav = document.querySelector('body > nav, #site > nav');
    if (!nav || nav.querySelector('.menu-toggle')) return;

    var GROUPS = [
        { title: null, links: [
            ['/docs/', 'Docs', 'menu-docs'],
            ['/vault/', 'Open the web app'],
        ] },
        { title: 'Nostr Vault', links: [
            ['/#trust', 'Trust'],
            ['/#feeds', 'Feeds'],
            ['/#features', 'Features'],
            ['/#web', 'Web'],
            ['/#platforms', 'Download'],
            ['/#relay', 'Relay'],
            ['/blog-what-is-nostr-vault.html', 'Blog'],
        ] },
        { title: 'Get the app', links: [
            ['https://testflight.apple.com/join/kN3zE1H1', 'iPhone and iPad (TestFlight)'],
            ['https://github.com/btcforplebs/nostr-vault/releases/latest', 'Android APK'],
            ['https://github.com/btcforplebs/nostr-vault/releases', 'Mac'],
        ] },
        { title: 'More', links: [
            ['https://github.com/btcforplebs/nostr-vault', 'GitHub'],
            ['https://github.com/btcforplebs/nostr-vault/blob/master/CHANGELOG.md', 'Changelog'],
            ['/privacy.html', 'Privacy Policy'],
            ['https://npub120rlujghxmnfz803syfemlv49zu565fpxjrt88wumwk4zjekwhkslyl4dc.nsite.lol/', 'The nsite copy'],
            ['https://btcforplebs.com', 'btcforplebs'],
        ] },
    ];

    var here = location.pathname;
    var menu = document.createElement('div');
    menu.className = 'site-menu';
    menu.id = 'site-menu';
    menu.hidden = true;
    GROUPS.forEach(function (g) {
        var group = document.createElement('div');
        group.className = 'site-menu-group';
        if (g.title) {
            var t = document.createElement('p');
            t.className = 'site-menu-title';
            t.textContent = g.title;
            group.appendChild(t);
        }
        g.links.forEach(function (l) {
            var a = document.createElement('a');
            a.href = l[0];
            a.textContent = l[1];
            if (l[2]) a.className = l[2];
            if (l[0] === here) a.setAttribute('aria-current', 'page');
            group.appendChild(a);
        });
        menu.appendChild(group);
    });

    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'menu-toggle';
    button.setAttribute('aria-label', 'Menu');
    button.setAttribute('aria-expanded', 'false');
    button.setAttribute('aria-controls', 'site-menu');
    button.innerHTML = '<span></span><span></span><span></span>';

    nav.appendChild(button);
    nav.appendChild(menu);
    nav.classList.add('has-menu');

    function set(open) {
        menu.hidden = !open;
        button.setAttribute('aria-expanded', open ? 'true' : 'false');
        nav.classList.toggle('menu-open', open);
    }

    button.addEventListener('click', function () { set(menu.hidden); });
    // A link closes the menu. On the home page a section link stays on the page (shell.js moves to it).
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) set(false); });
    document.addEventListener('click', function (e) { if (!menu.hidden && !nav.contains(e.target)) set(false); });
    document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && !menu.hidden) { set(false); button.focus(); }
    });
    // Back to a wide window: the header shows its own links again.
    window.matchMedia('(min-width: 961px)').addEventListener('change', function (m) { if (m.matches) set(false); });
})();
