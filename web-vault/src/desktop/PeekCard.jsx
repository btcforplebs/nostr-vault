// Hovering a name or avatar for 400ms shows a small profile card (design §3): name, NIP-05, about, and Follow.
// Mouse only: touch has no hover, and on the phone layout this isn't mounted.
import { useEffect, useRef, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "../components/Avatar.jsx"
import { useProfile } from "../components/useProfile.js"
import { setFollow } from "../net/follows.js"

const SHOW_MS = 400, HIDE_MS = 250
const HEX = /^[0-9a-f]{64}$/
const W = 300

/** The profile a hovered element points at, or null. Only inside the main area: the sidebar's own avatar is a menu. */
const targetOf = el => {
  const a = el?.closest?.('a[href^="#/profile/"]')
  if (!a || !a.closest(".desk-main")) return null
  const pk = a.getAttribute("href").slice("#/profile/".length)
  return HEX.test(pk) ? { a, pk } : null
}

export function PeekCard({ ctx }) {
  const [at, setAt] = useState(null) // { pubkey, left, top, above }
  const timers = useRef({})
  useEffect(() => {
    const t = timers.current
    const hideSoon = () => { clearTimeout(t.show); clearTimeout(t.hide); t.hide = setTimeout(() => setAt(null), HIDE_MS) }
    const over = e => {
      if (e.pointerType === "touch") return
      if (e.target.closest?.(".peek")) { clearTimeout(t.hide); return }
      const hit = targetOf(e.target)
      if (!hit) return
      clearTimeout(t.hide); clearTimeout(t.show)
      t.show = setTimeout(() => {
        if (!hit.a.isConnected) return
        const r = hit.a.getBoundingClientRect()
        const above = r.bottom + 220 > innerHeight
        setAt({ pubkey: hit.pk, left: Math.max(8, Math.min(r.left, innerWidth - W - 8)), top: above ? r.top - 8 : r.bottom + 8, above })
      }, SHOW_MS)
    }
    const out = e => { if (targetOf(e.target) || e.target.closest?.(".peek")) hideSoon() }
    const gone = () => { clearTimeout(t.show); setAt(null) }
    document.addEventListener("pointerover", over)
    document.addEventListener("pointerout", out)
    addEventListener("scroll", gone, true)
    addEventListener("hashchange", gone)
    const press = e => { if (!e.target.closest?.(".peek")) gone() }
    addEventListener("pointerdown", press)
    return () => {
      document.removeEventListener("pointerover", over); document.removeEventListener("pointerout", out)
      removeEventListener("scroll", gone, true); removeEventListener("hashchange", gone); removeEventListener("pointerdown", press)
      clearTimeout(t.show); clearTimeout(t.hide)
    }
  }, [])
  if (!at) return null
  return <Card ctx={ctx} {...at} />
}

function Card({ ctx, pubkey, left, top, above }) {
  const { vault, account, session, signer } = ctx
  const p = useProfile(pubkey)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState("")
  const npub = npubEncode(pubkey)
  const iFollow = account.follows.includes(pubkey)
  const me = pubkey === session.pubkey
  const toggle = async () => {
    setBusy(true); setErr("")
    try {
      await setFollow({ vault, signer, pubkey: session.pubkey, target: pubkey, follow: !iFollow,
        readRelays: account.relays.read, writeRelays: account.relays.write, known: account.contacts, appCount: account.follows.length })
      await ctx.reloadAccount()
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  return (
    <div class="peek" role="dialog" aria-label={`Profile: ${p?.name || npub.slice(0, 12)}`}
      style={{ left: `${left}px`, top: `${top}px`, width: `${W}px`, transform: above ? "translateY(-100%)" : undefined }}>
      <div class="peek-head">
        <Avatar pubkey={pubkey} size={44} />
        <div class="peek-names">
          <div class="peek-name">{p?.display_name || p?.name || npub.slice(0, 12) + "…"}</div>
          <div class="muted small peek-sub">{p?.nip05?.replace(/^_@/, "") || npub.slice(0, 16) + "…"}</div>
        </div>
      </div>
      {p?.about && <p class="peek-about">{p.about}</p>}
      <div class="peek-row">
        {me ? <span class="muted small">This is you</span> : iFollow ? <span class="peek-tag">You follow</span> : null}
        <span class="peek-actions">
          <a class="button small" href={`#/profile/${pubkey}`}>Profile</a>
          {!me && !signer?.readOnly && (
            <button type="button" class={iFollow ? "small" : "small primary"} disabled={busy || !account.loaded} onClick={toggle} aria-busy={busy || undefined}>
              {busy ? "…" : iFollow ? "Unfollow" : "Follow"}
            </button>
          )}
        </span>
      </div>
      {err && <p class="error small" role="alert">{err}</p>}
    </div>
  )
}
