// Docs pages: search, the phone-width menu, and old /docs/#anchor links. The pages work without it.
(function () {
    'use strict';

    // Old links into the first, single docs page (/docs/#kiosk and so on) go to the page that took that part over.
    var body = document.body;
    if (body.dataset.aliases && location.hash) {
        try {
            var to = JSON.parse(body.dataset.aliases)[location.hash];
            if (to) { location.replace(to); return; }
        } catch (e) { /* bad map: stay on the hub */ }
    }

    var side = document.querySelector('.docs-side');
    var menu = document.querySelector('.docs-menu');
    if (side && menu) {
        side.classList.add('js');
        menu.hidden = false;
        menu.addEventListener('click', function () {
            var open = side.classList.toggle('open');
            menu.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
    }

    var box = document.querySelector('.docs-search');
    var input = document.getElementById('docs-q');
    var list = document.getElementById('docs-results');
    if (!box || !input || !list) return;
    box.hidden = false;

    var index = null;
    var loading = null;
    var picked = -1;

    function load() {
        if (index || loading) return loading;
        loading = fetch('/docs/docs-search.json')
            .then(function (r) { return r.json(); })
            .then(function (j) { index = j; return j; })
            .catch(function () { index = []; });
        return loading;
    }

    function score(entry, terms) {
        var t = entry.t.toLowerCase(), h = entry.h.toLowerCase(), d = entry.d.toLowerCase(), x = entry.x.toLowerCase();
        var total = 0;
        for (var i = 0; i < terms.length; i++) {
            var q = terms[i], s = 0;
            if (t.indexOf(q) >= 0) s += 10;
            if (h.indexOf(q) >= 0) s += 5;
            if (d.indexOf(q) >= 0) s += 3;
            if (x.indexOf(q) >= 0) s += 1;
            if (!s) return 0;
            total += s;
        }
        return total;
    }

    function el(tag, text) {
        var n = document.createElement(tag);
        if (text) n.textContent = text;
        return n;
    }

    function render() {
        var q = input.value.trim().toLowerCase();
        list.textContent = '';
        picked = -1;
        if (!q || !index) { list.hidden = true; return; }
        var terms = q.split(/\s+/);
        var hits = index
            .map(function (e) { return { e: e, s: score(e, terms) }; })
            .filter(function (h) { return h.s > 0; })
            .sort(function (a, b) { return b.s - a.s; })
            .slice(0, 8);
        if (!hits.length) {
            var none = el('li', 'Nothing found.');
            none.className = 'empty';
            list.appendChild(none);
        }
        hits.forEach(function (h) {
            var li = el('li');
            var a = el('a', h.e.t);
            a.href = h.e.u;
            a.setAttribute('role', 'option');
            a.appendChild(el('span', h.e.s));
            li.appendChild(a);
            list.appendChild(li);
        });
        list.hidden = false;
    }

    function move(by) {
        var links = list.querySelectorAll('a');
        if (!links.length) return;
        if (picked >= 0) links[picked].removeAttribute('aria-selected');
        picked = (picked + by + links.length) % links.length;
        links[picked].setAttribute('aria-selected', 'true');
    }

    input.addEventListener('focus', load);
    input.addEventListener('input', function () { (load() || Promise.resolve()).then(render); render(); });
    input.addEventListener('keydown', function (ev) {
        if (ev.key === 'ArrowDown') { ev.preventDefault(); move(1); }
        else if (ev.key === 'ArrowUp') { ev.preventDefault(); move(-1); }
        else if (ev.key === 'Enter') {
            var links = list.querySelectorAll('a');
            var a = links[picked >= 0 ? picked : 0];
            if (a) location.href = a.href;
        } else if (ev.key === 'Escape') { input.value = ''; render(); }
    });
    document.addEventListener('click', function (ev) {
        if (!box.contains(ev.target)) list.hidden = true;
    });
})();
