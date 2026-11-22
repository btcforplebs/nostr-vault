// Your devices, on a box (One Vault W3): how the box is keeping up with each of your other vaults. The box pulls with
// its own mesh key (E3): it catches up every 15 minutes with each vault it has copied from, and the first copy from a
// vault is asked for here. The first account sees each device with its last copy, Sync now, and Copy from this vault
// (that vault builds its whole copy once). Any other signed-in account sees only that the box catches up, and one
// Sync now for all: the box shows the owner's devices only to the first account (Tron #2385 L2).
import { useEffect, useMemo, useState } from "preact/hooks"
import { decode } from "nostr-tools/nip19"
import { syncApi, syncErrorWords } from "../api-sync.js"
import { boxAccount } from "../box-vault.js"
import { lookInFront } from "../../components/auto-look.js"
import { ago, shortNpub } from "../format.js"

const hexOf = npub => { try { const d = decode(npub); return d.type === "npub" ? d.data : "" } catch { return "" } }

/** What one device's row says under its name, from GET sync's device. */
export function syncLine(d, { running, now = Date.now() / 1000 } = {}) {
  if (running === d.peer) return d.last?.kind === "first" ? "Copying from it now…" : "Catching up now…"
  if (d.reach) return `Can't reach it right now. ${d.token ? "The box tries again on its next round." : ""}`.trim()
  if (d.last?.error) return syncErrorWords(d.last.error)
  if (!d.token) return "Not copied to this box yet."
  const files = d.last?.files ? ` · ${d.last.files} new file${d.last.files === 1 ? "" : "s"}` : ""
  return d.syncedAt ? `Caught up ${ago(d.syncedAt, now)}${files}` : `Copied ${ago(d.last?.finished, now)}`
}

/** `api`: a syncApi (built from ctx.signer when not given; none: nothing shown). `names`: hex -> the device's name, where known.
 *  `account`: the page's boxAccountCheck (boxAccount() when not given). */
export function SyncRows({ ctx, api: given, names = new Map(), account: givenAccount }) {
  // No signer and no api (a harness's mock box): nothing to ask, nothing shown.
  const api = useMemo(() => given ?? (ctx.signer ? syncApi({ signer: ctx.signer }) : null), [given, ctx.signer])
  const account = givenAccount !== undefined ? givenAccount : boxAccount()
  const [who, setWho] = useState(account ? account.state : "first")
  useEffect(() => { if (!account) return; setWho(account.state); return account.subscribe(s => setWho(s.state)) }, [account])
  const [state, setState] = useState(null) // { value } | { error }
  const [said, setSaid] = useState({}) // peer ("" = all) -> { text, error }
  const [asking, setAsking] = useState("")
  const load = () => api.state().then(value => setState({ value }), e => setState({ error: String(e?.message ?? e) }))
  const member = !!api && (who === "first" || who === "signedIn")
  useEffect(() => { if (member) load() }, [api, member])
  // Every 4 s while a copy runs, so its row follows it; every 30 s otherwise.
  useEffect(() => member ? lookInFront(load, { every: state?.value?.busy ? 4000 : 30_000 }) : undefined, [api, member, state?.value?.busy])
  if (!member) return null

  // A note stands in for the row's state for a while, then the row says what the box says again.
  const note = (peer, n, ms) => {
    setSaid(s => ({ ...s, [peer]: n }))
    setTimeout(() => setSaid(s => (s[peer] === n ? (({ [peer]: _, ...rest }) => rest)(s) : s)), ms)
  }
  const ask = async (peer, how) => {
    setAsking(peer + how)
    try {
      await (how === "first" ? api.first(peer) : api.now(peer))
      note(peer, { text: how === "first" ? "Asked. That vault builds its copy first." : "Asked. It starts in a moment." }, 6000)
      setTimeout(load, 1500)
    } catch (e) {
      note(peer, { text: String(e?.message ?? e), error: true }, 15_000)
    } finally { setAsking("") }
  }

  const v = state?.value
  const first = who === "first"
  const devices = v?.devices ?? []
  const round = v?.busy || v?.round ? "Catching up now…" : v?.lastRound ? `Last checked ${ago(v.lastRound)}` : "Catches up every 15 minutes"
  return (
    <section class="settings-group box-sync" aria-label="Copies on this box">
      <div class="section-label">Copies on this box</div>
      <div class="settings-row box-row">
        <span class="settings-title">This box keeps a copy<span class="muted small box-sub">{state?.error ? state.error : !v ? "Asking the box…" : round}</span></span>
        {!first && v && <button type="button" class="small" disabled={asking === "now"} onClick={() => ask("", "now")}>Sync now</button>}
      </div>
      {!first && said[""] && <p class={`small box-pad ${said[""].error ? "error" : "muted"}`} role={said[""].error ? "alert" : undefined}>{said[""].text}</p>}
      {first && devices.map(d => {
        const title = names.get(hexOf(d.peer)) || shortNpub(d.peer)
        const told = said[d.peer]
        const running = v.running === d.peer
        return (
          <div key={d.peer} class="settings-row box-row box-sync-row">
            <span class="settings-title">{title}<span class={`small box-sub ${told?.error ? "error" : "muted"}`} role={told?.error ? "alert" : undefined}>{told ? told.text : syncLine(d, { running: v.running })}</span></span>
            {d.token && d.last?.error !== "auth_refused"
              ? <button type="button" class="small" disabled={running || !!asking} onClick={() => ask(d.peer, "now")}>Sync now</button>
              : <button type="button" class="small" disabled={running || v.busy || !!asking} onClick={() => ask(d.peer, "first")}>Copy from this vault</button>}
          </div>
        )
      })}
      {first && v && !devices.length && <p class="muted small box-pad">No other vaults paired with this box yet.</p>}
    </section>
  )
}
