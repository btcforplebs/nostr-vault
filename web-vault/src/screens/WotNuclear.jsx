// Nuclear unfollow on the Web of Trust globe (#/wot/<X>/nuke, from a profile's ··· menu; spec
// RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md). The globe lights your follows who follow X (WotScreen passes `cut`); this is
// the panel over it: a count and Show list, the list with a box per person (all checked), the warning (always one, a
// second from 25 people), then the steps as they happen ("Backup saved ✓" before anything is published) and Undo.
// The publish itself is net/nuclear-unfollow.js.
import { useEffect, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { Dialog } from "../components/Moderation.jsx"
import { getProfile } from "../net/profiles.js"
import { npubEncode } from "nostr-tools/nip19"
import { nuclearUnfollow, undoNuclear, warningsFor, pickedOf } from "../net/nuclear-unfollow.js"
if (import.meta.env) { import("../styles/wot.css"); import("../styles/wot-nuclear.css") } // wot.css too: on the desktop the WoT napplet pane has no WotScreen to load it

const nameOf = pk => getProfile(pk)?.name || npubEncode(pk).slice(0, 12) + "…"
const people = n => `${n.toLocaleString()} ${n === 1 ? "person" : "people"}`

/** `cut`: your follows who follow `target` (null while their lists load); `missing`: follows whose list didn't come
 *  back, so they couldn't be checked. `unfollow` is net/nuclear-unfollow.js nuclearUnfollow (a test hands in its own). */
export function NuclearPanel({ ctx, target, cut, missing = 0, unfollow = nuclearUnfollow }) {
  const followsTarget = ctx.account.follows.includes(target)
  // Everyone who would go, X first when you follow them: all checked to start.
  const everyone = cut ? [...(followsTarget ? [target] : []), ...cut] : null
  const [checked, setChecked] = useState(null)
  const [step, setStep] = useState("summary") // summary | list | warn1 | warn2 | working | done
  const [backedUp, setBackedUp] = useState(false)
  const [err, setErr] = useState("")
  const [result, setResult] = useState(null) // { event, base, removed }
  const [undo, setUndo] = useState("") // "" | "working" | "done"
  useEffect(() => { if (everyone && !checked) setChecked(new Set(everyone)) }, [everyone?.join()])
  // Only people on the list now and ticked: the count, the warnings and the unfollow all use this, never `checked`.
  const picked = pickedOf(everyone, checked)
  const n = picked.length
  const name = nameOf(target)
  const leave = () => { location.hash = `#/profile/${target}` }

  // A dialog's close (Escape, Cancel, a click outside) goes back to the list, but only while it is still the step: the
  // <dialog> also closes when it unmounts, as the first warning gives way to the second or to the run.
  const backFrom = which => () => setStep(s => (s === which ? "list" : s))
  const flip = pk => setChecked(c => { const next = new Set(c); if (next.has(pk)) next.delete(pk); else next.add(pk); return next })
  // Always one warning; from DOUBLE_WARN_AT people, a second one before anything starts.
  const confirmFirst = () => (warningsFor(n) === 2 ? setStep("warn2") : run())
  const run = async () => {
    setStep("working"); setErr(""); setBackedUp(false)
    try {
      const r = await unfollow({ ctx, target, remove: new Set(picked), onBackup: () => setBackedUp(true) })
      setResult(r); setStep("done")
      await ctx.reloadAccount?.()
    } catch (e) { setErr(String(e?.message ?? e)); setStep("list") }
  }
  const putBack = async () => {
    setUndo("working"); setErr("")
    try { await undoNuclear({ ctx, base: result.base, event: result.event }); setUndo("done"); await ctx.reloadAccount?.() } catch (e) { setErr(String(e?.message ?? e)); setUndo("") }
  }

  if (ctx.signer?.readOnly) return <div class="wot-note wot-nuke-panel" role="status">Signed in read-only: there's no key here to change your follow list.</div>
  if (!everyone) return <div class="wot-note wot-nuke-panel" role="status"><span class="wot-spin" aria-hidden="true" />Checking which of your follows follow {name}…</div>

  return (
    <>
      {step === "summary" && (
        <section class="wot-note wot-nuke-panel" aria-label="Nuclear unfollow">
          <p><b>{cut.length ? `${cut.length.toLocaleString()} of your follows follow ${name}` : `None of your follows follow ${name}`}</b>
            {cut.length > 0 && <span class="muted small"> They're lit on the globe.</span>}</p>
          {missing > 0 && <p class="muted small">{missing.toLocaleString()} of your follows' lists didn't load, so they weren't checked.</p>}
          <div class="mod-row">
            <button type="button" onClick={leave}>Cancel</button>
            <button type="button" class="danger-fill" disabled={!everyone.length} onClick={() => setStep("list")}>Show list</button>
          </div>
        </section>
      )}
      {(step === "list" || step === "warn1" || step === "warn2") && (
        <section class="wot-list wot-nuke-list" role="region" aria-label="Who would be unfollowed">
          <header class="wot-list-head">
            <b>Unfollow · {n.toLocaleString()} of {everyone.length.toLocaleString()}</b>
            <span>
              <button type="button" class="small" onClick={() => setChecked(new Set(n === everyone.length ? [] : everyone))}>{n === everyone.length ? "Uncheck all" : "Check all"}</button>
              <button type="button" class="small" onClick={() => setStep("summary")}>Globe</button>
            </span>
          </header>
          <p class="muted small wot-nuke-why">Uncheck anyone you want to keep following.</p>
          <ul class="wot-list-rows">
            {everyone.map(pk => (
              <li key={pk}>
                <label class="wot-list-row wot-nuke-row">
                  <input type="checkbox" checked={checked?.has(pk)} onChange={() => flip(pk)} />
                  <Avatar pubkey={pk} size={36} />
                  <span class="wot-list-text"><AuthorName pubkey={pk} /><span class="muted small">{pk === target ? "The person you're cutting" : `Follows ${name}`}</span></span>
                </label>
              </li>
            ))}
          </ul>
          {err && <p class="error small" role="alert">{err}</p>}
          <button type="button" class="danger-fill wot-nuke-go" disabled={!n} onClick={() => setStep("warn1")}>Unfollow {people(n)}</button>
        </section>
      )}
      {step === "warn1" && (
        <Dialog label={`Unfollow ${people(n)}`} onClose={backFrom("warn1")}>
          <h3>Unfollow {people(n)}?</h3>
          <p class="muted">{n === 1 ? "They'll" : "They'll all"} be taken out of your follow list in one change. Your current list is backed up first, and you can undo it afterwards.</p>
          <div class="mod-row">
            <button type="button" onClick={() => setStep("list")}>Cancel</button>
            <button type="button" class="danger-fill" onClick={confirmFirst}>Unfollow {people(n)}</button>
          </div>
        </Dialog>
      )}
      {step === "warn2" && (
        <Dialog label="Are you sure?" onClose={backFrom("warn2")}>
          <h3>That's {people(n)}. Are you sure?</h3>
          <p class="muted">This is a big change to who you follow: your feed, your web and your notifications will all change. The backup lets you undo it, but other apps will see the new list at once.</p>
          <div class="mod-row">
            <button type="button" onClick={() => setStep("list")}>Go back</button>
            <button type="button" class="danger-fill" onClick={run}>Yes, unfollow {people(n)}</button>
          </div>
        </Dialog>
      )}
      {(step === "working" || step === "done") && (
        <section class="wot-note wot-nuke-panel" aria-label="Nuclear unfollow" role="status">
          <p>{backedUp ? "Backup saved ✓" : <><span class="wot-spin" aria-hidden="true" />Backing up your follow list…</>}</p>
          {step === "working" && backedUp && <p><span class="wot-spin" aria-hidden="true" />{ctx.signer?.method === "nip46" ? "Waiting for your signer…" : "Publishing your new follow list…"}</p>}
          {step === "done" && <p><b>Unfollowed {people(result.removed.length)}.</b></p>}
          {undo === "done" && <p>Undone: your follow list is back as it was.</p>}
          {err && <p class="error small" role="alert">{err}</p>}
          {step === "done" && (
            <div class="mod-row">
              {undo !== "done" && <button type="button" disabled={undo === "working"} onClick={putBack} aria-busy={undo === "working" || undefined}>{undo === "working" ? "Undoing…" : "Undo"}</button>}
              <button type="button" class="primary" onClick={leave}>Done</button>
            </div>
          )}
        </section>
      )}
    </>
  )
}
