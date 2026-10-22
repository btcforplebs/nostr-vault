#!/usr/bin/env node
// Builds nostrvault.app/docs/ from the page sources in website/docs/_src/. No dependencies.
//
//   node website/docs/_tools/build.mjs            write the pages, the nav and docs-search.json
//   node website/docs/_tools/build.mjs --check    fail if a built file is stale, an image is missing or a /docs/ link is dead
//   node website/docs/_tools/build.mjs --labels [--root <checkout>]
//                                                 fail if a UI label a page quotes is not in that app's source
//
// A source is an HTML fragment. Its first lines are a JSON comment, the page's front matter:
//
//   <!--page
//   { "title": "Get started on iPhone", "nav": "iPhone", "section": "start", "order": 1,
//     "description": "…", "eyebrow": "Get started", "needs": "3.0",
//     "labels": { "ios": ["Create an account"], "android": [], "mac": [], "web": [] } }
//   -->
//
// _src/start/iphone.html becomes /docs/start/iphone/index.html; _src/index.html is /docs/ itself.
// "needs": "3.0" puts the 3.0 banner on top. "aliases" lists old /docs/#anchors that should land here.
// Optional: "h1" (HTML, defaults to the title), "lede" (HTML), "checked" (the app version the page was checked against).
// "labels" are the exact strings the page tells people to tap. --labels greps them in the app sources
// (run it against the branch the page describes: 3.0 pages against integrate/v3.0.0).
// The built pages are committed, so the site image serves them as they are.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DOCS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC = path.join(DOCS, '_src');
const REPO = path.resolve(DOCS, '..', '..');

// Nav order. A section with no pages is left out.
const SECTIONS = [
    { key: 'start', title: 'Get started' },
    { key: 'keys', title: 'Keys and accounts' },
    { key: 'mesh', title: 'Mesh and your devices' },
    { key: 'vault', title: 'Your vault' },
    { key: 'media', title: 'Media and sharing' },
    { key: 'help', title: 'Help' },
    { key: 'dev', title: 'Developers' },
];

const BANNERS = {
    '3.0': '<strong>3.0 coming soon.</strong> This page is about Nostr Vault 3.0, which is in testing. The apps you can download today are 2.7.2.',
};

const LABEL_SOURCES = {
    ios: { dirs: ['HavenApp/HavenApp', 'HavenApp/HavenApp-iOS', 'HavenApp/NostrVaultShare'], ext: ['.swift', '.xcstrings'] },
    mac: { dirs: ['HavenApp/HavenApp'], ext: ['.swift', '.xcstrings'] },
    android: { dirs: ['NostrVault/app/src/main'], ext: ['.kt', '.xml'] },
    web: { dirs: ['web-vault/src', 'web-relay/src', 'web-relay/index.html'], ext: ['.js', '.jsx', '.html'] },
};

function walk(dir, ext, out = []) {
    if (!fs.existsSync(dir)) return out;
    if (fs.statSync(dir).isFile()) {
        if (ext.some((e) => dir.endsWith(e))) out.push(dir);
        return out;
    }
    for (const name of fs.readdirSync(dir).sort()) {
        if (name === 'node_modules' || name.startsWith('.')) continue;
        walk(path.join(dir, name), ext, out);
    }
    return out;
}

function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function stripTags(html) {
    return html.replace(/<[^>]+>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&rarr;/g, '→').replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&middot;/g, '·').replace(/&[a-z]+;/g, ' ')
        .replace(/\s+/g, ' ').trim();
}

function slug(s) {
    return stripTags(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

function readPages() {
    const pages = [];
    for (const file of walk(SRC, ['.html'])) {
        const rel = path.relative(SRC, file).replace(/\\/g, '/');
        const raw = fs.readFileSync(file, 'utf8');
        const m = raw.match(/^<!--page\s*([\s\S]*?)-->\s*/);
        if (!m) throw new Error(`${rel}: no <!--page {…} --> front matter`);
        let meta;
        try { meta = JSON.parse(m[1]); } catch (e) { throw new Error(`${rel}: front matter is not JSON: ${e.message}`); }
        for (const k of ['title', 'description', 'section']) if (!meta[k]) throw new Error(`${rel}: front matter needs "${k}"`);
        if (meta.section !== 'home' && !SECTIONS.some((s) => s.key === meta.section)) throw new Error(`${rel}: unknown section "${meta.section}"`);
        if (meta.needs && !BANNERS[meta.needs]) throw new Error(`${rel}: unknown "needs" "${meta.needs}"`);
        const urlPath = rel === 'index.html' ? '' : rel.replace(/\.html$/, '').replace(/\/index$/, '') + '/';
        pages.push({ rel, meta, body: raw.slice(m[0].length), url: `/docs/${urlPath}`, out: path.join(DOCS, urlPath, 'index.html') });
    }
    return pages;
}

function navOrder(pages) {
    const out = [];
    for (const s of SECTIONS) {
        const list = pages.filter((p) => p.meta.section === s.key)
            .sort((a, b) => (a.meta.order ?? 99) - (b.meta.order ?? 99) || a.url.localeCompare(b.url));
        if (list.length) out.push({ ...s, pages: list });
    }
    return out;
}

// Give each <h2> an id, and collect them for "On this page".
function anchorHeadings(body) {
    const heads = [];
    const html = body.replace(/<h2(\s[^>]*)?>([\s\S]*?)<\/h2>/g, (all, attrs = '', inner) => {
        const idm = attrs.match(/\sid="([^"]+)"/);
        const id = idm ? idm[1] : slug(inner);
        heads.push({ id, text: stripTags(inner) });
        return idm ? all : `<h2 id="${id}"${attrs}>${inner}</h2>`;
    });
    return { html, heads };
}

function renderNav(sections, current) {
    return sections.map((s) => `
            <div class="docs-nav-group">
                <p class="docs-nav-title">${esc(s.title)}</p>
                <ul>
${s.pages.map((p) => `                    <li><a href="${p.url}"${p === current ? ' aria-current="page"' : ''}>${esc(p.meta.nav || p.meta.title)}${p.meta.needs ? ` <span class="docs-nav-tag">${esc(p.meta.needs)}</span>` : ''}</a></li>`).join('\n')}
                </ul>
            </div>`).join('');
}

function renderToc(sections) {
    return `<div class="docs-hub">${sections.map((s) => `
            <section class="docs-hub-group">
                <h2 id="${s.key}">${esc(s.title)}</h2>
                <div class="docs-cards">
${s.pages.map((p) => `                    <a class="docs-card" href="${p.url}">
                        <h3>${esc(p.meta.title)}${p.meta.needs ? ` <span class="tag tag-test">${esc(p.meta.needs)}</span>` : ''}</h3>
                        <p>${esc(p.meta.description)}</p>
                    </a>`).join('\n')}
                </div>
            </section>`).join('')}
        </div>`;
}

function renderPage(page, sections, flat, aliases) {
    const { meta } = page;
    const isHome = meta.section === 'home';
    let { html: body, heads } = anchorHeadings(page.body.trim());
    if (isHome) body = body.replace('<!--toc-->', renderToc(sections));
    const i = flat.indexOf(page);
    const prev = i > 0 ? flat[i - 1] : null;
    const next = i >= 0 && i < flat.length - 1 ? flat[i + 1] : null;
    const canonical = `https://nostrvault.app${page.url}`;
    const fullTitle = isHome ? 'Docs — Nostr Vault' : `${meta.title} — Nostr Vault Docs`;
    const onPage = !isHome && heads.length >= 3
        ? `\n            <div class="docs-onpage" role="navigation" aria-label="On this page"><p>On this page</p><ul>${heads.map((h) => `<li><a href="#${h.id}">${esc(h.text)}</a></li>`).join('')}</ul></div>`
        : '';
    const banner = meta.needs ? `\n            <div class="docs-banner" role="note">${BANNERS[meta.needs]}</div>` : '';
    const pager = (prev || next) && !isHome ? `
            <div class="docs-pager" role="navigation" aria-label="Next and previous">
                ${prev ? `<a class="prev" href="${prev.url}"><span>Previous</span>${esc(prev.meta.nav || prev.meta.title)}</a>` : '<span></span>'}
                ${next ? `<a class="next" href="${next.url}"><span>Next</span>${esc(next.meta.nav || next.meta.title)}</a>` : '<span></span>'}
            </div>` : '';
    const checked = meta.checked ? `\n            <p class="docs-checked">Checked against ${esc(meta.checked)}.</p>` : '';
    const aliasAttr = isHome && Object.keys(aliases).length ? ` data-aliases="${esc(JSON.stringify(aliases))}"` : '';

    return `<!DOCTYPE html>
<!-- Built by website/docs/_tools/build.mjs from website/docs/_src/${page.rel}. Edit the source, then run the build. -->
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${esc(fullTitle)}</title>
    <meta name="description" content="${esc(meta.description)}">
    <link rel="canonical" href="${canonical}">
    <meta name="theme-color" content="#000000">
    <meta property="og:type" content="article">
    <meta property="og:site_name" content="Nostr Vault">
    <meta property="og:url" content="${canonical}">
    <meta property="og:title" content="${esc(fullTitle)}">
    <meta property="og:description" content="${esc(meta.description)}">
    <meta property="og:image" content="https://nostrvault.app/assets/og-image.jpg">
    <meta name="twitter:card" content="summary_large_image">
    <link rel="icon" type="image/png" href="/assets/haven_icon.png">
    <link rel="apple-touch-icon" href="/assets/haven_icon.png">
    <link rel="stylesheet" href="/style.css">
    <link rel="stylesheet" href="/docs/docs.css">
    <script src="/docs/docs.js" defer></script>
</head>

<body class="docs-body"${aliasAttr}>

    <nav>
        <a class="logo" href="/" aria-label="Nostr Vault home">
            <img src="/assets/haven_icon.png" alt="" width="32" height="32">
            <span>NOSTR VAULT</span>
        </a>
        <div class="nav-links">
            <a href="/#features">Features</a>
            <a href="/#web">Web</a>
            <a href="/#platforms">Download</a>
            <a href="/docs/" aria-current="page">Docs</a>
            <a href="/blog-what-is-nostr-vault.html">Blog</a>
        </div>
        <div class="actions">
            <a href="/vault/" class="pill pill-web">Open web app <span class="beta">Beta</span></a>
            <a href="https://github.com/btcforplebs/nostr-vault" class="pill pill-light">GitHub</a>
        </div>
    </nav>

    <div class="docs-layout">
        <aside class="docs-side" aria-label="Docs">
            <button class="docs-menu" type="button" aria-expanded="false" aria-controls="docs-nav" hidden>Docs menu</button>
            <div class="docs-search" hidden>
                <input type="search" id="docs-q" placeholder="Search the docs" aria-label="Search the docs" autocomplete="off">
                <ul class="docs-results" id="docs-results" role="listbox" hidden></ul>
            </div>
            <div class="docs-nav" id="docs-nav">
                <p class="docs-nav-home"><a href="/docs/"${isHome ? ' aria-current="page"' : ''}>Docs home</a></p>${renderNav(sections, page)}
            </div>
        </aside>

        <main class="docs-main${isHome ? ' docs-home' : ''}">
            <p class="eyebrow">${esc(meta.eyebrow || (isHome ? 'Docs' : (SECTIONS.find((s) => s.key === meta.section) || {}).title || 'Docs'))}</p>
            <h1>${meta.h1 || esc(meta.title)}</h1>${meta.lede ? `\n            <p class="docs-lede">${meta.lede}</p>` : ''}${banner}${onPage}

            <article class="docs-article">
${body.split('\n').map((l) => (l ? `                ${l}` : l)).join('\n')}
            </article>${checked}${pager}
        </main>
    </div>

    <footer>
        <p>&copy; 2026 Nostr Vault. Built on top of the incredible work by <a href="https://github.com/bitvora/haven">bitvora</a>
            and <a href="https://github.com/barrydeen/haven">barrydeen</a>.</p>
        <p class="footer-small">Made by <a href="https://btcforplebs.com">btcforplebs</a> &middot; <a href="/privacy.html">Privacy Policy</a> &middot; <a href="https://github.com/btcforplebs/nostr-vault/blob/master/CHANGELOG.md">Changelog</a></p>
    </footer>

</body>

</html>
`;
}

function searchIndex(flat, home) {
    return JSON.stringify([home, ...flat].filter(Boolean).map((p) => {
        const { heads } = anchorHeadings(p.body);
        return {
            u: p.url,
            t: p.meta.title,
            s: (SECTIONS.find((s) => s.key === p.meta.section) || { title: 'Docs' }).title,
            d: p.meta.description,
            h: heads.map((h) => h.text).join(' · '),
            x: stripTags(p.body.replace('<!--toc-->', '')).slice(0, 4000),
        };
    })) + '\n';
}

function build() {
    const pages = readPages();
    const sections = navOrder(pages);
    const flat = sections.flatMap((s) => s.pages);
    const home = pages.find((p) => p.meta.section === 'home');
    if (!home) throw new Error('_src/index.html (section "home") is missing');
    const aliases = {};
    // "aliases": ["#kiosk"] lands on the page; {"#kiosk": "#kiosk"} lands on an anchor in it.
    for (const p of pages) {
        const list = p.meta.aliases || [];
        const entries = Array.isArray(list) ? list.map((a) => [a, '']) : Object.entries(list);
        for (const [a, anchor] of entries) {
            if (aliases[a]) throw new Error(`alias ${a} is claimed by ${aliases[a]} and ${p.url}`);
            aliases[a] = p.url + anchor;
        }
    }
    const files = new Map();
    for (const p of pages) files.set(p.out, renderPage(p, sections, flat, aliases));
    files.set(path.join(DOCS, 'docs-search.json'), searchIndex(flat, home));
    return { pages, files };
}

function check({ pages, files }) {
    const problems = [];
    for (const [file, text] of files) {
        const rel = path.relative(REPO, file);
        if (!fs.existsSync(file)) problems.push(`${rel}: not built`);
        else if (fs.readFileSync(file, 'utf8') !== text) problems.push(`${rel}: stale, run the build`);
    }
    // A built page whose source is gone.
    for (const f of walk(DOCS, ['index.html'])) {
        if (f.includes(`${path.sep}_src${path.sep}`)) continue;
        if (!files.has(f)) problems.push(`${path.relative(REPO, f)}: has no source in _src/`);
    }
    const urls = new Set(pages.map((p) => p.url));
    for (const p of pages) {
        for (const [, src] of p.body.matchAll(/\ssrc="(\/[^"]+)"/g)) {
            if (!fs.existsSync(path.join(REPO, 'website', src))) problems.push(`${p.rel}: missing image ${src}`);
        }
        for (const [, href] of p.body.matchAll(/\shref="(\/docs\/[^"#?]*)/g)) {
            const target = href.endsWith('/') ? href : href + '/';
            if (!urls.has(target) && !fs.existsSync(path.join(REPO, 'website', href))) problems.push(`${p.rel}: dead link ${href}`);
        }
        for (const [, img] of p.body.matchAll(/<img\b([^>]*)>/g)) {
            if (!/\salt="/.test(img)) problems.push(`${p.rel}: an <img> has no alt`);
        }
    }
    return problems;
}

function labels(pages, root) {
    const corpus = {};
    for (const [plat, { dirs, ext }] of Object.entries(LABEL_SOURCES)) {
        corpus[plat] = dirs.flatMap((d) => walk(path.join(root, d), ext))
            .filter((f) => !/Tests?\//.test(f))
            .map((f) => fs.readFileSync(f, 'utf8')).join('\n');
    }
    // Positive control: the check has to be able to fail, and has to see real source.
    const control = '__docs_label_check_control__';
    for (const [plat, text] of Object.entries(corpus)) {
        if (text.length < 10000) return [`${plat}: no source found under ${root} (wrong --root?)`];
        if (text.includes(control)) return [`${plat}: control label found, the check cannot fail`];
    }
    const problems = [];
    for (const p of pages) {
        for (const [plat, list] of Object.entries(p.meta.labels || {})) {
            if (!corpus[plat]) { problems.push(`${p.rel}: unknown platform "${plat}"`); continue; }
            for (const label of list) {
                const variants = [label, label.replace(/'/g, "\\'"), label.replace(/'/g, '’'), label.replace(/&/g, '&amp;')];
                if (!variants.some((v) => corpus[plat].includes(v))) problems.push(`${p.rel}: ${plat} has no "${label}"`);
            }
        }
    }
    return problems;
}

const args = process.argv.slice(2);
const result = build();
if (args.includes('--check')) {
    const problems = check(result);
    if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
    console.log(`docs: ${result.pages.length} pages up to date`);
} else if (args.includes('--labels')) {
    const i = args.indexOf('--root');
    const root = path.resolve(i >= 0 ? args[i + 1] : REPO);
    const problems = labels(result.pages, root);
    if (problems.length) { console.error(problems.join('\n')); process.exit(1); }
    const n = result.pages.reduce((a, p) => a + Object.values(p.meta.labels || {}).flat().length, 0);
    console.log(`docs: ${n} labels found in ${root}`);
} else {
    for (const [file, text] of result.files) {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, text);
    }
    console.log(`docs: built ${result.pages.length} pages`);
}
