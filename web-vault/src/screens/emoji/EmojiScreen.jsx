// Vault › Emoji (custom emoji v1, RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4.4): the emoji sets your list (kind 10030) names,
// each with its images, how many the apps saved in your vault, and a Dead links section for images no server has any
// more (each is looked for on other servers first). Browse to add someone's set; open one to remove it. Loose emoji
// in the list that belong to no set are not shown (Logen's pick 6). The web saves no copies: Save copies and zip import
// need the app on your phone or Mac, which signs the emoji notes with its mesh key (Tod 2026-11-13 13:24Z).
import { useState } from "preact/hooks"
import { VaultPagesMenu } from "../VaultPagesMenu.jsx"
import { SkeletonList } from "../../components/Loading.jsx"
import { useEmojiVault } from "./useEmojiVault.js"
import { EmojiGrid } from "./EmojiGrid.jsx"
import { EmojiSetHead } from "./EmojiSetHead.jsx"
import { EmojiSetDetail } from "./EmojiSetDetail.jsx"
import { EmojiBrowse } from "./EmojiBrowse.jsx"
import { deadLinks } from "../../net/emoji-links.js"
if (import.meta.env) import("../../styles/emoji.css")

export const APP_ONLY = "Do this in the app on your phone or Mac. It saves the images in your vault and they show here."

export function EmojiScreen({ ctx }) {
  const v = useEmojiVault(ctx)
  const [view, setView] = useState({ id: "mine" })
  const [note, setNote] = useState("")
  const listed = new Set((v.sets ?? []).map(s => s.address))
  const readOnly = !!ctx.signer?.readOnly
  const head = <header class="screen-head"><VaultPagesMenu ctx={ctx} current="emoji" /><h2 class="sr-only">Emoji</h2></header>

  if (view.id === "browse") return <main class="screen emoji">{head}<EmojiBrowse ctx={ctx} listed={listed} onBack={() => setView({ id: "mine" })} onOpen={set => setView({ id: "set", set, from: "browse" })} /></main>
  if (view.id === "set") {
    const set = (v.sets ?? []).find(s => s.address === view.set.address) ?? view.set
    return (
      <main class="screen emoji">{head}
        <EmojiSetDetail set={set} inList={listed.has(set.address)} canEdit={v.list.checked} readOnly={readOnly} links={v.links} saved={v.saved}
          onChange={v.setOn} onBack={() => setView({ id: view.from ?? "mine" })} />
      </main>
    )
  }

  const savedIn = set => set.emoji.filter(e => v.saved(set, e)).length
  const all = [...(v.sets ?? []), ...v.others]
  const dead = deadLinks(all, v.links, v.saved)
  return (
    <main class="screen emoji">
      {head}
      <div class="emoji-actions">
        <button type="button" class="primary" onClick={() => setView({ id: "browse" })}>Browse sets</button>
        <button type="button" onClick={() => setNote(APP_ONLY)}>Save copies</button>
        <button type="button" onClick={() => setNote(APP_ONLY)}>Import zip</button>
      </div>
      {note && <p class="status-line" role="status">{note}</p>}
      {!v.homeVault && <p class="status-line muted small">Saved copies show here when this browser is your home vault.</p>}
      {v.sets === null ? <SkeletonList rowClass="emoji-set" label="Reading your emoji list…" />
        : !all.length ? <p class="empty">No emoji sets in your list yet. Browse sets to add one.</p>
        : <>
          {v.sets.map(set => (
            <div key={set.address} class="emoji-set">
              <EmojiSetHead set={set} savedCount={v.homeVault ? savedIn(set) : null} onOpen={() => setView({ id: "set", set })} />
              <EmojiGrid set={set} links={v.links} saved={v.saved} />
            </div>
          ))}
          {v.others.length > 0 && <div class="section-label">Saved, not in your list</div>}
          {v.others.map(set => (
            <div key={set.address} class="emoji-set">
              <EmojiSetHead set={set} savedCount={savedIn(set)} badge="Not in your list" onOpen={() => setView({ id: "set", set })} />
              <EmojiGrid set={set} links={v.links} saved={v.saved} />
            </div>
          ))}
          {dead.length > 0 && (
            <section class="emoji-dead">
              <div class="section-label">Dead links ({dead.length})</div>
              <p class="muted small">No server has these images any more. {v.homeVault ? "The ones marked saved are safe in your vault." : ""}</p>
              {dead.map(d => (
                <div key={`${d.set.address} ${d.code}`} class="emoji-dead-row">
                  <b>:{d.code}:</b><span class="muted small">{d.set.title}</span>
                  <span class="muted small emoji-url">{d.url}</span>
                  {d.saved && <span class="emoji-badge">Saved</span>}
                </div>
              ))}
            </section>
          )}
        </>}
    </main>
  )
}
