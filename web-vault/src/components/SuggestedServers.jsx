// Settings › Media Servers › Suggested (iPhone SuggestedMediaServersSection): servers the account hasn't listed yet,
// each with Add. Adding only changes the draft list; "Save and publish" on the page still publishes it.
import { notYetAdded, suggestionHost } from "../net/suggested-servers.js"

export function SuggestedServers({ urls, disabled, onAdd }) {
  const suggestions = notYetAdded(urls)
  if (!suggestions.length) return null
  return (
    <section class="settings-group relay-list">
      <div class="section-label">Suggested</div>
      {suggestions.map(s => (
        <div key={s.url} class="settings-row static relay-edit-row">
          <span class="settings-title"><span class="mono">{suggestionHost(s.url)}</span><span class="server-health muted">{s.note}</span></span>
          <span class="settings-tags">
            <button type="button" class="small" disabled={disabled} aria-label={`Add ${suggestionHost(s.url)}`} onClick={() => onAdd(s.url)}>Add</button>
          </span>
        </div>
      ))}
      <p class="settings-note muted small">Servers other Nostr apps use. Prices and limits are set by each server and can change.</p>
    </section>
  )
}
