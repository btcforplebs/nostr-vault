// The public profile page, nostrvault.app/p/<npub>: what the apps' Share profile QR code and link open. Drawn on the
// server like the post page (page.js), so it opens signed out and a chat app that unfurls the link reads its og: tags.
// It runs no script: "Open in Nostr Vault" is a plain nostrvault://p/<npub> link, which the iPhone, Mac and Android
// apps open on that profile (or, before setup, as the person who told you about Nostr Vault). Someone without the app
// gets it from the site, or opens the profile in any other Nostr app (nostr:).
// This file is the pure half: the address and the HTML. The relay read is loadProfile in fetch.js.
import { decode, npubEncode } from "nostr-tools/nip19"
import { SITE, esc, httpsUrl, page } from "./page.js"

const HEX64 = /^[0-9a-f]{64}$/
const ABOUT_LIMIT = 600

/** The person a /p/ address names. Takes npub and nprofile (with or without "nostr:").
 *  -> { pubkey, npub, relays } | null. A bare hex key is refused: the apps only ever share npubs. */
export function parseProfileTarget(raw) {
  const s = String(raw ?? "").trim().replace(/^nostr:/i, "")
  let d
  try { d = decode(s) } catch { return null }
  if (d.type === "npub" && HEX64.test(d.data)) return { pubkey: d.data, npub: npubEncode(d.data), relays: [] }
  if (d.type === "nprofile" && HEX64.test(d.data.pubkey)) return { pubkey: d.data.pubkey, npub: npubEncode(d.data.pubkey), relays: d.data.relays ?? [] }
  return null
}

/** The address Share profile writes. */
export const profileUrl = npub => `${SITE}/p/${npub}`

/** Where "Open in Nostr Vault" goes: the apps' own scheme, so no other Nostr app answers it. */
export const appProfileLink = npub => `nostrvault://p/${npub}`

/** A kind 0's fields for the page. -> { name, picture, banner, about, nip05 } with nulls where it says nothing usable. */
export function profileFields(ev) {
  let p = {}
  try { p = JSON.parse(ev?.content ?? "{}") ?? {} } catch {}
  const str = v => (typeof v === "string" && v.trim() ? v.trim() : null)
  const about = str(p.about)
  return {
    name: str(p.display_name) ?? str(p.displayName) ?? str(p.name),
    picture: httpsUrl(p.picture),
    banner: httpsUrl(p.banner),
    about: about && about.length > ABOUT_LIMIT ? `${about.slice(0, ABOUT_LIMIT - 1).trimEnd()}…` : about,
    nip05: str(p.nip05),
  }
}

const shortNpub = npub => `${npub.slice(0, 12)}…${npub.slice(-6)}`

/** The whole page. `profile`: the newest kind 0, or null when no relay had one (the page still works: the link opens
 *  the app on that key). */
export function renderProfile({ target, profile }) {
  const f = profile ? profileFields(profile) : { name: null, picture: null, banner: null, about: null, nip05: null }
  const name = f.name ?? shortNpub(target.npub)
  const url = profileUrl(target.npub)
  const meta = {
    title: `${name} on Nostr`,
    description: f.about ?? `Follow ${name} on Nostr with Nostr Vault.`,
    image: f.picture ?? `${SITE}/assets/og-image.jpg`,
    imageIsMedia: false,
    url, type: "profile",
  }
  const avatar = f.picture
    ? `<img class="av" src="${esc(f.picture)}" alt="" width="96" height="96" referrerpolicy="no-referrer">`
    : `<span class="av av-none" aria-hidden="true">${esc([...name][0]?.toUpperCase() ?? "?")}</span>`
  const body = `
<article class="post profile">
  ${f.banner ? `<img class="banner" src="${esc(f.banner)}" alt="" referrerpolicy="no-referrer">` : ""}
  <div class="who">
    ${avatar}
    <h1>${esc(name)}</h1>
    ${f.nip05 ? `<p class="nip05">${esc(f.nip05.replace(/^_@/, ""))}</p>` : ""}
    <p class="npub">${esc(target.npub)}</p>
  </div>
  ${f.about ? `<p class="about">${esc(f.about)}</p>` : ""}
</article>
<div class="join">
  <p><strong>Follow ${esc(name)} on Nostr.</strong> Open this profile in Nostr Vault. New to Nostr? Get the app first, then open this link again: ${esc(name)} is the first person you follow, and you can pick from the people they follow.</p>
  <div class="open">
    <a class="btn primary" href="${esc(appProfileLink(target.npub))}">Open in Nostr Vault</a>
    <a class="btn" href="/">Get Nostr Vault</a>
    <a class="btn" href="nostr:${esc(target.npub)}">Open in another Nostr app</a>
  </div>
</div>`
  return page({ meta, body, css: CSS })
}

/** The page for an address that is not a profile. */
export function renderProfileMissing({ code }) {
  const body = `
<article class="post missing">
  <h1>That isn't a Nostr profile link</h1>
  <p>A profile link ends in npub1….</p>
</article>
<div class="open"><a class="btn primary" href="/">Get Nostr Vault</a></div>`
  return page({
    meta: { title: "Profile not found · Nostr Vault", description: "A profile on Nostr, shared from Nostr Vault.", image: `${SITE}/assets/og-image.jpg`, url: `${SITE}/p/${code}`, type: "website" },
    body, noindex: true,
  })
}

const CSS = `
.profile{padding:0;overflow:hidden}
.profile .banner{display:block;width:100%;height:160px;object-fit:cover;background:#111}
.who{display:flex;flex-direction:column;align-items:center;text-align:center;padding:20px 20px 0}
.profile .banner+.who{margin-top:-58px}
.who .av{width:96px;height:96px;border:3px solid #000;font-size:38px}
.who h1{font-size:24px;line-height:1.2;letter-spacing:-.01em;margin:12px 0 2px;overflow-wrap:anywhere}
.nip05{color:var(--dim);font-size:14px}
.npub{color:var(--dim);font:12px/1.4 ui-monospace,Menlo,monospace;margin-top:6px;overflow-wrap:anywhere;user-select:all}
.about{white-space:pre-wrap;overflow-wrap:anywhere;padding:14px 20px 20px;text-align:center;font-size:16px}
.profile .who:last-child{padding-bottom:20px}
`
