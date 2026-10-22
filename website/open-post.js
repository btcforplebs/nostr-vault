// The public post page (/thread/<nevent>, web-vault/thread-page) sends a browser straight into the web app on that
// post: someone signed in opens it in their account, anyone else as a guest (web-vault/src/guest). The page names the
// address in <meta name="nv-open">. Link previews (chat apps, crawlers) run no script, so they keep the page's og: card.
// replace(), so Back leaves rather than landing here again.
const to = document.querySelector('meta[name="nv-open"]')?.getAttribute("content")
if (to && to.startsWith("/vault/#/thread/")) location.replace(to)
