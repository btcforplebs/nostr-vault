// Sell something: a NIP-99 classified listing (kind 30402), as the iPhone's MarketplaceSellView: photos (at least one,
// the first is the cover in the grid), what you're selling, a one-line summary, a price in sats or a currency, a
// category, a location and a description. "List it" signs it and sends it to your write relays and the marketplace
// relays (where the grid, Shopstr and Plebeian look). Opened from Marketplace's "Sell something"
// (#/compose?type=listing). What isn't listed yet is kept as a draft.
import { useEffect, useRef, useState } from "preact/hooks"
import { publishKind } from "../../net/sync.js"
import { mediaServers, uploadPhoto } from "../../net/upload.js"
import { uniq } from "../../net/pool.js"
import { Dialog } from "../../components/Moderation.jsx"
import { canGoBack } from "../../components/nav-depth.js"
import { PostResult } from "./PostResult.jsx"
import { forgetIfSent, idbDrafts } from "./drafts.js"
import { MARKET_RELAYS } from "../../readers/market.js"
import { CURRENCIES, EMPTY_LISTING, LISTING_CATEGORIES, LISTING_KIND, MAX_PHOTOS, buildListing, canPublishListing, hasListing,
  listingDraftOf, listingFromDraft, listingHint } from "../../readers/listing.js"

if (import.meta.env) { import("../../readers/readers.css"); import("../../styles/listing-compose.css") }

const DRAFT_KEY = "listing"
let nextPhoto = 0

export function ListingCompose({ ctx }) {
  const [l, setL] = useState(EMPTY_LISTING)
  const set = patch => setL(cur => ({ ...cur, ...patch }))
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState(null)
  const [err, setErr] = useState("")
  const [leaving, setLeaving] = useState(false)

  const drafts = useRef(null)
  drafts.current ??= idbDrafts(ctx.session.pubkey)
  const [loaded, setLoaded] = useState(false)
  useEffect(() => {
    let live = true
    drafts.current.get(DRAFT_KEY).catch(() => null).then(d => {
      if (!live) return
      if (d) setL(listingFromDraft(d))
      setLoaded(true)
    })
    return () => { live = false }
  }, [])
  const saving = useRef(Promise.resolve())
  const kept = JSON.stringify(listingDraftOf(l))
  useEffect(() => {
    if (!loaded) return
    const d = JSON.parse(kept)
    saving.current = saving.current.then(() => (hasListing(l) ? drafts.current.put(DRAFT_KEY, d) : drafts.current.delete(DRAFT_KEY))).catch(() => {})
  }, [kept, loaded])

  // Photos go up one after another, as they're picked, to the account's media servers.
  const queue = useRef(Promise.resolve())
  const servers = useRef(null)
  const patchPhoto = (id, patch) => setL(cur => ({ ...cur, photos: cur.photos.map(p => (p.id === id ? { ...p, ...patch } : p)) }))
  const upload = (id, file) => {
    patchPhoto(id, { status: "uploading", error: "" })
    queue.current = queue.current.then(async () => {
      try {
        servers.current ??= await mediaServers(ctx)
        const up = await uploadPhoto(file, { ctx, servers: servers.current })
        patchPhoto(id, { ...up, status: "done", file: null })
      } catch (e) { patchPhoto(id, { status: "failed", error: String(e?.message ?? e) }) }
    })
  }
  const addFiles = files => {
    const images = [...files].filter(f => /^image\//.test(f.type))
    if (!images.length) return
    setErr("")
    setL(cur => {
      const room = MAX_PHOTOS - cur.photos.length
      if (images.length > room) setErr(`A listing can carry ${MAX_PHOTOS} photos.`)
      const added = images.slice(0, Math.max(0, room)).map(file => ({ id: `p${++nextPhoto}`, file, preview: URL.createObjectURL(file), status: "queued" }))
      queueMicrotask(() => added.forEach(p => upload(p.id, p.file)))
      return { ...cur, photos: [...cur.photos, ...added] }
    })
  }
  const removePhoto = p => {
    if (p.preview?.startsWith("blob:")) URL.revokeObjectURL(p.preview)
    setL(cur => ({ ...cur, photos: cur.photos.filter(x => x.id !== p.id) }))
  }
  const picker = useRef(null)

  const uploading = l.photos.some(p => p.status === "uploading" || p.status === "queued")
  const canPost = !busy && !uploading && canPublishListing(l)
  const hint = listingHint(l, { uploading })

  const publish = async e => {
    e?.preventDefault()
    if (!canPost) return
    setErr(""); setResult(null); setBusy(true)
    try {
      const { content, tags } = buildListing(l)
      // The marketplace relays too: that's where the grid, Shopstr and Plebeian look; your own relays rarely are.
      const sent = await publishKind(ctx.vault, ctx.signer, ctx.session.pubkey, LISTING_KIND, content, uniq([...ctx.account.relays.write, ...MARKET_RELAYS]), tags)
      setResult(sent)
      const clear = () => { for (const p of l.photos) if (p.preview?.startsWith("blob:")) URL.revokeObjectURL(p.preview); setL(EMPTY_LISTING) }
      if (await forgetIfSent(sent, { stopSaving: () => setLoaded(false), clear, saving, drafts: drafts.current, key: DRAFT_KEY })) {
        setLoaded(true)
        if (canGoBack()) history.back()
      } else setErr("Not sent to any relay. Your listing is still here: try again.")
    } catch (e) { setErr(String(e?.message ?? e)) } finally { setBusy(false) }
  }
  const cancel = () => (hasListing(l) ? setLeaving(true) : history.back())
  const discard = async () => {
    await saving.current
    await drafts.current.delete(DRAFT_KEY).catch(() => {})
    setLoaded(false)
    setL(EMPTY_LISTING); setLeaving(false)
    history.back()
  }

  const field = (key, props) => ({ value: l[key], readOnly: busy, onInput: e => set({ [key]: e.currentTarget.value }), ...props })
  const label = busy ? (ctx.signer.method === "nip46" ? "Waiting for your signer…" : "Listing…") : uploading ? "Uploading…" : "List it"
  return (
    <main class="screen compose-sheet compose-article compose-listing">
      <header class="compose-bar">
        <button type="button" class="compose-cancel" onClick={cancel}>Cancel</button>
        <h2>Sell something</h2>
        <button type="submit" form="listing-form" class="compose-post" disabled={!canPost} aria-busy={busy || uploading || undefined}>{label}</button>
      </header>
      <form id="listing-form" class="kind-form" onSubmit={publish}>
        <fieldset class="kind-group">
          <legend>Photos</legend>
          <div class="listing-photos">
            {l.photos.map((p, i) => (
              <div key={p.id} class={`listing-photo ${p.status}`}>
                <img src={p.preview} alt="" />
                {i === 0 && <span class="listing-cover">Cover</span>}
                {p.status !== "done" && <span class="listing-photo-state">{p.status === "failed" ? "Failed" : "Uploading…"}</span>}
                <button type="button" class="listing-photo-remove" aria-label="Remove photo" disabled={busy} onClick={() => removePhoto(p)}>✕</button>
              </div>
            ))}
            {l.photos.length < MAX_PHOTOS && (
              <button type="button" class="listing-photo-add" disabled={busy} onClick={() => picker.current.click()}>{l.photos.length ? "Add" : "Add photos"}</button>
            )}
          </div>
          <input ref={picker} type="file" accept="image/*" multiple hidden onChange={e => { addFiles(e.currentTarget.files); e.currentTarget.value = "" }} />
          <p class="muted small kind-note">At least one. The first is the cover in the grid.</p>
          {l.photos.filter(p => p.status === "failed").map(p => <p key={p.id} class="error small">{p.error}</p>)}
        </fieldset>
        <input class="kind-title" type="text" placeholder="What are you selling?" aria-label="What are you selling?" {...field("title")} />
        <input class="kind-field" type="text" placeholder="One-line summary (optional)" aria-label="Summary" {...field("summary")} />
        <fieldset class="kind-group">
          <legend>Price</legend>
          <div class="listing-price">
            <input class="kind-field" type="text" inputmode="decimal" placeholder={l.currency === "SATS" ? "21000" : "45.00"} aria-label="Price" {...field("price")} />
            <select class="kind-field" aria-label="Currency" value={l.currency} disabled={busy} onChange={e => set({ currency: e.currentTarget.value })}>
              {CURRENCIES.map(c => <option key={c} value={c}>{c === "SATS" ? "sats" : c}</option>)}
            </select>
          </div>
        </fieldset>
        <fieldset class="kind-group">
          <legend>Category and location</legend>
          <select class="kind-field" aria-label="Category" value={l.category} disabled={busy} onChange={e => set({ category: e.currentTarget.value })}>
            {LISTING_CATEGORIES.map(c => <option key={c} value={c}>{c === "Other" ? "None" : c}</option>)}
          </select>
          <input class="kind-field" type="text" placeholder="Location (optional)" aria-label="Location" {...field("location")} />
        </fieldset>
        <fieldset class="kind-group">
          <legend>Description</legend>
          <textarea class="kind-field" rows={6} aria-label="Description" {...field("description")} />
          <p class="muted small kind-note">Condition, size, shipping, and how buyers should pay or reach you. Buyers see this here and on Plebeian Market, and can message you from the listing.</p>
        </fieldset>
        {hint && <p class="muted small kind-note" role="status">{hint}</p>}
        {loaded && hasListing(l) && !result && <p class="muted small kind-note">Draft saved</p>}
      </form>
      {leaving && (
        <Dialog label="Save this listing as a draft?" onClose={() => setLeaving(false)}>
          <h3>Save this listing as a draft?</h3>
          <p class="muted small">Drafts stay in this browser.</p>
          <div class="mod-row compose-leave">
            <button type="button" class="primary" onClick={() => { setLeaving(false); history.back() }}>Save Draft</button>
            <button type="button" class="danger" onClick={discard}>Discard</button>
            <button type="button" onClick={() => setLeaving(false)}>Keep Editing</button>
          </div>
        </Dialog>
      )}
      {err && <p class="error">{err}</p>}
      {result && <PostResult result={result} />}
    </main>
  )
}
