// My Web, the Web of Trust tab's dashboard (iPhone TrustWebView+MyWeb, MyWebDashboardView): a sheet over the globe with
// how many people are in your web, a row per layer that puts it on the globe, Follow you back, and Rebuild your web.
// Built from the Vault Dashboard's parts (components/dashboard/parts.jsx). Left out, as the tab's bar leaves them out:
// Talk with you (the browser keeps no history of who you talk with) and Live arrivals / What flies (no stars fly here).
import { useEffect } from "preact/hooks"
import { Section, RowButton, Chevron } from "../components/dashboard/parts.jsx"
import { WOT_GLOBE } from "../components/wot-glyph.js"
import { EXTENDED_MIN, LAYERS } from "../net/wot.js"
import { WotIcon } from "./WotTopBar.jsx"
if (import.meta.env) import("../styles/dashboard.css")

const DETAIL = {
  everyone: "Your whole web",
  following: "People you follow",
  close: `Followed by ${EXTENDED_MIN}+ people you follow`,
  furtherOut: `Followed by fewer than ${EXTENDED_MIN} people you follow`,
}

export const WotGlobeIcon = ({ size = 18 }) => <svg viewBox="0 0 24 24" width={size} height={size} fill="currentColor" aria-hidden="true"><path d={WOT_GLOBE} /></svg>

/** One row that picks something: icon, title and detail, its count, then a check when it's on or a chevron. */
function CountRow({ icon, title, detail, count, selected, onClick }) {
  return (
    <button type="button" class={`dash-row link wot-count-row${selected ? " on" : ""}`} aria-pressed={selected} onClick={onClick}>
      <span class="dash-icon info" aria-hidden="true"><WotIcon name={icon} size={16} /></span>
      <span class="dash-text"><span class="dash-title">{title}</span><span class="dash-sub">{detail}</span></span>
      <span class="wot-count">{count == null ? "–" : count.toLocaleString()}</span>
      {selected ? <span class="wot-count-check" aria-hidden="true">✓</span> : <Chevron />}
    </button>
  )
}

/** `counts`: layerCounts of your web; `follows` and `followsBack`: how many you follow, and how many of them follow you
 *  (null until their lists are in). A layer or the filter puts it on the globe and closes the sheet. */
export function WotMyWeb({ counts, layer, follows, followsBack, followsBackOn, missing, rebuilding, onLayer, onFollowsBack, onRebuild, onClose }) {
  useEffect(() => {
    const key = e => { if (e.key === "Escape") onClose() }
    addEventListener("keydown", key)
    return () => removeEventListener("keydown", key)
  }, [])
  const everyone = counts?.everyone ?? 0
  const upkeep = rebuilding ? "Rebuilding now…"
    : missing > 0 ? `${missing.toLocaleString()} of your follows' lists didn't arrive, so part of your web is missing. Rebuild asks for them again`
    : "Built from your follows' lists, kept in this browser"
  return (
    <div class="dash-sheet" role="dialog" aria-modal="true" aria-labelledby="wot-myweb-title">
      <div class="dash-scrim" onClick={onClose} />
      <div class="dash-panel">
        <header class="dash-bar-top">
          <span />
          <h2 id="wot-myweb-title"><WotIcon name="everyone" size={17} />My Web</h2>
          <button type="button" class="dash-link done" onClick={onClose} autofocus>Done</button>
        </header>
        <div class="dash-scroll">
          <div class="wot-myweb-head">
            <span class="wot-myweb-mark"><WotGlobeIcon size={34} /></span>
            <span>
              <b>{everyone.toLocaleString()} {everyone === 1 ? "person" : "people"}</b>
              <small>in your web: who you follow, and who they follow</small>
            </span>
          </div>
          <Section title="Who you can see">
            {LAYERS.map(([id, title]) => (
              <CountRow key={id} icon={id} title={title} detail={DETAIL[id]} count={counts?.[id] ?? 0} selected={layer === id} onClick={() => onLayer(id)} />
            ))}
          </Section>
          <Section title="With you">
            <CountRow icon="followsBack" title="Follow you back" selected={followsBackOn} count={followsBack} onClick={onFollowsBack}
              detail={followsBack != null && follows > 0 ? `${followsBack.toLocaleString()} of the ${follows.toLocaleString()} people you follow` : "Checking who follows you…"} />
          </Section>
          <Section title="Upkeep">
            <div class="dash-row">
              <span class="dash-icon info" aria-hidden="true"><WotIcon name="rebuild" size={16} /></span>
              <span class="dash-text"><span class="dash-title">Rebuild your web</span><span class="dash-sub">{upkeep}</span></span>
              <RowButton title="Rebuild" busy={rebuilding} onClick={onRebuild} />
            </div>
          </Section>
        </div>
      </div>
    </div>
  )
}
