// nostrvault.app opens the web app first: /vault/ full screen in a frame over this page. "What is Nostr Vault?" (the
// app's welcome screen, its menu, or a link to #about / any section) shrinks the app into the phone in the hero, and
// the marketing page comes in around it. The app keeps running in the phone; "Open the app" grows it back.
// The app reaches this page as window.nvShell (web-vault/src/shell.js). Without JavaScript the page is the plain
// marketing page, and its /vault/ links open the app on its own.
(() => {
    if (window.top !== window) return; // never a shell inside a frame
    const slot = document.querySelector('.phone-slot');
    const site = document.getElementById('site');
    if (!slot || !site) return;

    const root = document.documentElement;
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
    const EASE = 'cubic-bezier(0.45, 0, 0.15, 1)';
    const MS = 760;
    const RADIUS = '36px';
    const SHADOW_OFF = '0 0 0 0 #0a0a0a, 0 0 0 0 rgba(255,255,255,0)';
    const SHADOW_ON = '0 0 0 6px #0a0a0a, 0 0 0 7px rgba(255,255,255,0.08)'; // the phone's bezel

    // "#/…" is an address in the app; any other hash is a place on the marketing page.
    const appHash = h => h.startsWith('#/');
    const sectionOf = h => (h && h !== '#' && !appHash(h) ? h.slice(1) : '');

    const wrap = document.createElement('div');
    wrap.className = 'live-app';
    const frame = document.createElement('iframe');
    frame.title = 'Nostr Vault';
    frame.src = '/vault/' + (appHash(location.hash) ? location.hash : '');
    wrap.append(frame);
    document.body.append(wrap);
    root.classList.add('shell');

    let mode = 'app';
    let running = null; // the animations in flight

    // The app hides its own "What is Nostr Vault?" while the page is already out (web-vault/src/styles/welcome.css).
    const tell = () => { try { frame.contentDocument.documentElement.dataset.shell = mode; } catch {} };

    // The app's own address shows in this page's, so a reload or a copied link opens the same screen.
    const mirror = () => {
        if (mode !== 'app') return;
        let h = '';
        try { h = frame.contentWindow.location.hash; } catch { return; }
        const want = location.pathname + location.search + (appHash(h) ? h : '');
        if (want !== location.pathname + location.search + location.hash) history.replaceState(null, '', want);
    };
    frame.addEventListener('load', () => {
        try { frame.contentWindow.addEventListener('hashchange', mirror); } catch {}
        tell();
        mirror();
    });

    const viewport = () => ({ top: '0px', left: '0px', width: `${innerWidth}px`, height: `${innerHeight}px` });
    const box = r => ({ top: `${r.top}px`, left: `${r.left}px`, width: `${r.width}px`, height: `${r.height}px` });

    // At rest in the phone: placed on the slot in page coordinates, so it scrolls with the page.
    const place = () => {
        if (mode !== 'learn' || running) return;
        const r = slot.getBoundingClientRect();
        Object.assign(wrap.style, { position: 'absolute', ...box({ top: r.top + scrollY, left: r.left + scrollX, width: r.width, height: r.height }) });
    };
    new ResizeObserver(place).observe(slot);
    addEventListener('resize', place);
    addEventListener('load', place); // the copy above can still move the phone once fonts and images are in
    document.fonts?.ready.then(place);

    const setInert = on => {
        site.inert = on;
        on ? site.setAttribute('aria-hidden', 'true') : site.removeAttribute('aria-hidden');
    };

    function stop() {
        running?.forEach(a => a.cancel());
        running = null;
    }

    function animate(from, to, onDone) {
        const ms = reduce.matches ? 0 : MS;
        Object.assign(wrap.style, { position: 'fixed', ...to.rect, borderRadius: to.radius, boxShadow: to.shadow });
        const opts = { duration: ms, easing: EASE };
        running = [
            wrap.animate([{ ...from.rect, borderRadius: from.radius, boxShadow: from.shadow }, { ...to.rect, borderRadius: to.radius, boxShadow: to.shadow }], opts),
            site.animate([{ opacity: from.site }, { opacity: to.site }], { ...opts, duration: ms * 0.8 }),
        ];
        Promise.all(running.map(a => a.finished)).then(() => { running = null; onDone(); }, () => {});
    }

    /** App -> phone on the marketing page. `section`: scroll there once the phone is in place. */
    function learn(section = '') {
        if (mode === 'learn') { if (section) go(section); return; }
        stop();
        mode = 'learn';
        tell();
        root.classList.remove('shell-app');
        root.classList.add('shell-learn');
        setInert(false);
        frame.blur();
        scrollTo({ top: 0, behavior: 'instant' });
        history.replaceState(null, '', location.pathname + location.search + '#' + (section || 'about'));
        const r = slot.getBoundingClientRect();
        animate({ rect: viewport(), radius: '0px', shadow: SHADOW_OFF, site: 0 }, { rect: box(r), radius: RADIUS, shadow: SHADOW_ON, site: 1 }, () => {
            wrap.classList.add('framed');
            wrap.style.boxShadow = '';
            wrap.style.borderRadius = '';
            place();
            if (section && section !== 'about') go(section);
            else document.querySelector('.hero h1')?.focus({ preventScroll: true });
        });
    }

    /** Phone -> the app full screen. */
    function open() {
        if (mode === 'app') return;
        stop();
        const r = wrap.getBoundingClientRect();
        wrap.classList.remove('framed');
        mode = 'app';
        tell();
        animate({ rect: box(r), radius: RADIUS, shadow: SHADOW_ON, site: 1 }, { rect: viewport(), radius: '0px', shadow: SHADOW_OFF, site: 0 }, () => {
            root.classList.remove('shell-learn');
            root.classList.add('shell-app');
            setInert(true);
            wrap.removeAttribute('style');
            scrollTo({ top: 0, behavior: 'instant' });
            mirror();
            frame.focus();
        });
    }

    const go = section => {
        const el = document.getElementById(section);
        if (el) el.scrollIntoView({ behavior: reduce.matches ? 'auto' : 'smooth', block: 'start' });
    };

    window.nvShell = { learn, open };

    // The page's own links: the web app opens here, a section link leaves the app first.
    document.addEventListener('click', e => {
        const a = e.target.closest('a[href]');
        if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        const url = new URL(a.href, location.href);
        if (url.origin !== location.origin) return;
        if (url.pathname === '/vault/' || url.pathname === '/vault/index.html') {
            e.preventDefault();
            if (appHash(url.hash)) frame.contentWindow.location.hash = url.hash;
            open();
        }
    });
    document.querySelectorAll('.js-open-app').forEach(b => b.addEventListener('click', open));

    // Back/forward between a section and the app's address, or a typed #section.
    addEventListener('hashchange', () => {
        const s = sectionOf(location.hash);
        if (s) learn(s);
        else if (appHash(location.hash)) { try { frame.contentWindow.location.hash = location.hash; } catch {} open(); }
    });

    // The first frame: the app, or (opened on #features, #about, …) the marketing page with the phone already in place.
    const first = sectionOf(location.hash);
    if (first) {
        mode = 'learn';
        tell();
        root.classList.add('shell-learn');
        wrap.classList.add('framed');
        requestAnimationFrame(() => { place(); if (first !== 'about') go(first); });
    } else {
        root.classList.add('shell-app');
        setInert(true);
    }
})();
