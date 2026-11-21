// Settings › Relays › Recommended (iPhone RelayMatrixView's Recommended page, same wording and order): relays your
// follows write to, most follows first, then the well-known public relays that answer fastest from this browser. Add
// puts a relay in Your Relays (the page's draft); Save and publish there publishes it, as on the phone.
import { useEffect, useMemo, useState } from "preact/hooks"
import { pool } from "../net/pool.js"
import { WELL_KNOWN_RELAYS, followOutboxes, followSuggestions, followsWithRelayLists, fastest, relayKey } from "../net/relay-suggestions.js"

/** `rows`: Your Relays as drafted; `probes`: url -> probe result (net/relay-probe.js); `probe(urls)` times relays not
 *  yet asked; `RelayName` draws a relay with its timing line; `add(url, { read, write })` adds it to the draft. */
export function RelaysRecommended({ ctx, rows, probes, probe, RelayName, add, locked, readOnly }) {
  const follows = ctx.account?.follows ?? []
  const [outbox, setOutbox] = useState(null) // Map pubkey -> write relays, null while loading
  useEffect(() => {
    let live = true
    probe(WELL_KNOWN_RELAYS.filter(u => !blocked(u)))
    followOutboxes({ vault: ctx.vault, follows, relays: ctx.account?.relays?.read ?? [] })
      .then(m => { if (live) setOutbox(m) }, () => { if (live) setOutbox(new Map()) })
    return () => { live = false }
  }, [])

  const taken = rows.map(r => r.url)
  // Ranked once the lists are in, against the relays you had then (RelayMatrixView.refreshSuggestions); one you add
  // after drops out without the rest moving (visibleFollowSuggestions).
  const suggestions = useMemo(() => outbox ? followSuggestions({ follows, outbox, taken, blocked }) : [], [outbox])
  useEffect(() => { if (suggestions.length) probe(suggestions.map(s => s.url)) }, [suggestions])
  const withLists = outbox ? followsWithRelayLists(follows, outbox) : 0
  const yours = new Set(taken.map(relayKey))
  const visible = suggestions.filter(s => !yours.has(relayKey(s.url)) && !probes[s.url]?.why)

  const ms = {}
  for (const [url, r] of Object.entries(probes)) if (r?.ms != null) ms[relayKey(url)] = r.ms
  // A relay already suggested above isn't repeated here.
  const quick = fastest(WELL_KNOWN_RELAYS, ms, { taken: [...taken, ...visible.map(s => s.url)], blocked })
  const measuring = WELL_KNOWN_RELAYS.some(u => !blocked(u) && !probes[u])

  return (
    <>
      <section class="settings-group relay-list" aria-labelledby="rec-follows">
        <div class="section-label" id="rec-follows">Your Follows Write To</div>
        {!outbox ? <p class="settings-note muted small" role="status">Loading your follows' relay lists…</p>
          : !visible.length && <p class="settings-note muted small">{withLists === 0
            ? "None of your follows' relay lists have loaded yet."
            : "You already read from the relays your follows use most."}</p>}
        {visible.map(s => (
          <Suggestion key={s.url} url={s.url} result={probes[s.url]} RelayName={RelayName} detail={`${s.follows} follows write here`}
            readOnly={readOnly} locked={locked} onAdd={() => add(s.url, { read: true, write: false })} />
        ))}
        <p class="settings-note muted small">Add puts it in Your Relays with Read; Save publishes it. Based on {withLists} of your {follows.length} follows' relay lists.</p>
      </section>
      <section class="settings-group relay-list" aria-labelledby="rec-fastest">
        <div class="section-label" id="rec-fastest">Fastest From This Device</div>
        {!quick.length && <p class="settings-note muted small" role="status">{measuring ? "Measuring…" : "Nothing faster to suggest."}</p>}
        {quick.map(url => (
          <Suggestion key={url} url={url} result={probes[url]} RelayName={RelayName}
            readOnly={readOnly} locked={locked} onAdd={() => add(url, { read: true, write: true })} />
        ))}
        <p class="settings-note muted small">Well-known public relays, timed from here just now. Add puts it in Your Relays with Read and Write; Save publishes it.</p>
      </section>
    </>
  )
}

/** RelayMatrixView.suggestionRow: the relay with its timing (and how many follows write there), then Add. */
function Suggestion({ url, result, RelayName, detail, readOnly, locked, onAdd }) {
  return (
    <div class="settings-row static relay-edit-row">
      <RelayName url={url} result={result} detail={detail} />
      {!readOnly && <span class="settings-tags">
        <button type="button" class="small primary" disabled={locked} aria-label={`Add ${url.replace(/^wss:\/\//, "")}`} onClick={onAdd}>Add</button>
      </span>}
    </div>
  )
}

/** On your Never Connect list: never suggested. */
const blocked = url => !!pool.neverConnect?.(url)
