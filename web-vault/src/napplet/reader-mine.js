// Your own profile in the Reader (plan NV_WEB_ONE_PLAN.md step 5): the Reader draws the page, the shell answers what
// only it holds and runs what must stay its own. Kind 0 signing never reaches the frame: Edit Profile opens the site's
// own editor (EditProfile.jsx) over the Reader, as the full composer does for Post (step 2b).
//   napplet:profile/mine {}            -> { data }: your names, about, pictures, chips, counts and whether this sign-in can
//                                         sign (mineAnswer). Your notes the Reader reads itself (outbox, as every list).
//   napplet:profile/shop {}            -> { data: rows }: your listings (net/profile-tabs.js fetchShop), shaped to draw
//   napplet:profile/listing { id }     -> the site's listing page over the Reader, for a listing it handed out only
//   napplet:profile/edit {}            -> the site's Edit Profile (refused for a read-only sign-in)
//   napplet:profile/share {}           -> the site's Share sheet for your profile
//   napplet:profile/copy { what }      -> copies your npub ("npub") or lightning address ("ln"), nothing the frame names
//   napplet:page/open { page }         -> one of PAGES (Wallet, Settings, Web of Trust); anything else opens nothing
// All of them answer the Reader only.
import { READER_DTAG as READER } from "./first-party-list.js"

/** The pages your profile's buttons open. */
export const PAGES = { wallet: "#/wallet", settings: "#/settings", wot: "#/wot" }

const str = (v, max) => (typeof v === "string" ? v.slice(0, max) : "")
const https = v => (/^https:\/\//i.test(v ?? "") ? String(v).slice(0, 2048) : "")
const http = v => (/^https?:\/\//i.test(v ?? "") ? String(v).slice(0, 2048) : "")

/** napplet:profile/mine: the header as the site's ProfileHeader draws it, as plain strings and numbers. */
export function mineAnswer({ me, npub, profile: p, follows, followers, readOnly }) {
  return {
    pubkey: me, npub,
    name: str(p?.display_name || p?.name, 80), nip05: str(p?.nip05, 120).replace(/^_@/, ""), about: str(p?.about, 2000),
    picture: https(p?.picture), banner: https(p?.banner), website: http(p?.website), lud16: str(p?.lud16, 120),
    following: Number.isInteger(follows) ? follows : null, followers: Number.isInteger(followers) ? followers : null,
    canEdit: !readOnly,
  }
}

/** napplet:profile/shop: your listings (readers/market.js listing shape) -> rows to draw, the first picture https only. */
export const shopRows = (listings, priceOf) => (listings ?? []).slice(0, 100).map(l => ({
  id: l.id, title: str(l.title, 200), summary: str(l.summary, 400), price: str(priceOf(l), 60), image: https(l.images?.[0]), auction: !!l.isAuction,
}))

/**
 * Registers the handlers on `bus`. `profile()` -> mineAnswer's input; `shop()` -> listings; `onEdit`, `onShare`,
 * `onListing(listing)`, `onPage(hash)`, `copy(text)`. -> off()
 */
export function mineIntents({ bus, profile, shop, priceOf, onEdit, onShare, onListing, onPage, copy }) {
  let handed = new Map() // id -> listing, the ones profile/shop last handed out
  const reader = (h, run) => bus.register({ id: `shell-${h.archetype}-${h.actions[0]}`, title: "Profile", conventions: [], ...h, deliver: (p, from) =>
    (from?.dTag !== READER ? { ok: false, error: "the Reader's only" } : run(p ?? {})) })
  const offs = [
    reader({ archetype: "profile", actions: ["mine"] }, async () => ({ ok: true, data: mineAnswer(await profile()) })),
    reader({ archetype: "profile", actions: ["shop"] }, async () => {
      const list = await shop().catch(() => [])
      handed = new Map(list.map(l => [l.id, l]))
      return { ok: true, data: shopRows(list, priceOf) }
    }),
    reader({ archetype: "profile", actions: ["listing"] }, p => {
      const l = handed.get(p.id)
      if (!l) return { ok: false, error: "not a listing this profile shows" }
      onListing(l)
      return { ok: true }
    }),
    reader({ archetype: "profile", actions: ["edit"] }, async () => {
      if ((await profile()).readOnly) return { ok: false, error: "this sign-in can't sign" }
      onEdit()
      return { ok: true }
    }),
    reader({ archetype: "profile", actions: ["share"] }, () => { onShare(); return { ok: true } }),
    reader({ archetype: "profile", actions: ["copy"] }, async p => {
      const a = mineAnswer(await profile())
      const text = p.what === "npub" ? a.npub : p.what === "ln" ? a.lud16 : ""
      if (!text) return { ok: false, error: "nothing to copy" }
      await copy(text)
      return { ok: true }
    }),
    reader({ archetype: "page", actions: ["open"] }, p => {
      const to = Object.hasOwn(PAGES, p.page) ? PAGES[p.page] : null
      if (!to) return { ok: false, error: "not a page" }
      onPage(to)
      return { ok: true }
    }),
  ]
  return () => offs.forEach(off => off())
}
