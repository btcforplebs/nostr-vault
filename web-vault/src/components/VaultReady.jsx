// "Getting your vault ready": the first sign-in's wait while the in-page relay starts and fills (net/vault-ready.js),
// shown as the steps it is on and one bar for the whole, so the app opens full instead of on half-empty screens.
// Open now leaves the rest to carry on in the background. Styles: styles/vault-ready.css.
import { STEPS, progressOf } from "../net/vault-ready.js"
import { Spinner } from "./Loading.jsx"
import "../styles/vault-ready.css"

const n = v => (v ?? 0).toLocaleString()

/** The line under a step's title: what it has counted so far, or why it let go. */
export function stepDetail(id, s) {
  if (!s) return ""
  if (s.state === "slow") return "Finishing in the background"
  if (s.state === "failed") return "Couldn't reach your relays; it will try again"
  if (id === "account" && s.state === "done") return s.count ? `Following ${n(s.count)}` : "Not following anyone yet"
  if (id === "notes" && s.count != null) return `${n(s.count)} saved`
  if (id === "feed" && s.of) return `${n(s.done)} of ${n(s.of)} people · ${n(s.count)} notes saved`
  if (id === "feed" && s.state === "done" && s.count === 0) return "Nothing to fetch yet"
  if (id === "profiles" && s.of) return `${n(s.done)} of ${n(s.of)}`
  return ""
}

function StepIcon({ state }) {
  if (state === "active") return <span class="vr-icon"><Spinner /></span>
  if (state === "done") return <span class="vr-icon vr-done" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" /></svg></span>
  if (state === "slow" || state === "failed") return <span class="vr-icon vr-later" aria-hidden="true">…</span>
  return <span class="vr-icon vr-wait" aria-hidden="true" />
}

const STATE_WORD = { active: "in progress", done: "done", slow: "continuing in the background", failed: "skipped" }

/** `steps`: { [id]: { state, done, of, count } } as prepareVault reports them. */
export function VaultReady({ steps, onOpen }) {
  const pct = Math.round(progressOf(steps) * 100)
  const current = STEPS.find(s => steps[s.id]?.state === "active")
  return (
    <main class="vault-ready" aria-busy="true">
      <span class="splash-mark"><img src="./icon.svg" alt="" /></span>
      <h1>Getting your vault ready</h1>
      <p class="vr-lede">Your vault runs right here in this tab. The first time, it fetches your notes and the people you follow, so the app opens full. Next time it opens straight away.</p>
      <div class="vr-bar" role="progressbar" aria-label="Getting your vault ready" aria-valuemin="0" aria-valuemax="100" aria-valuenow={pct}
        aria-valuetext={current ? `${pct}%, ${current.title.toLowerCase()}` : `${pct}%`}>
        <span style={{ width: `${pct}%` }} />
      </div>
      <ol class="vr-steps">
        {STEPS.map(({ id, title }) => {
          const s = steps[id], state = s?.state ?? "waiting", detail = stepDetail(id, s)
          return (
            <li key={id} class={`vr-step is-${state}`} aria-current={state === "active" ? "step" : undefined}>
              <StepIcon state={state} />
              <span class="vr-text">
                <span class="vr-title">{title}<span class="sr-only">, {STATE_WORD[state] ?? "waiting"}</span></span>
                {detail && <span class="vr-detail">{detail}</span>}
              </span>
            </li>
          )
        })}
      </ol>
      <button type="button" class="vr-open" onClick={onOpen}>Open now, finish in the background</button>
    </main>
  )
}
