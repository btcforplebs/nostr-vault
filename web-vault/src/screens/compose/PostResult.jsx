// What a post reached once it's sent: the relay count first, then what failed. Shared by every composer.
const host = url => url.replace(/^wss?:\/\//, "")

// The count reached first, then what failed. This machine's own relay is reported apart, and quietly:
// it being off doesn't mean the note didn't go out.
export function PostResult({ result }) {
  const network = result.relays.filter(r => !r.local)
  const reached = network.filter(r => r.ok)
  const failed = network.filter(r => !r.ok)
  return (
    <div class="result" role="status">
      <strong class={reached.length ? "" : "error"}>
        {reached.length ? `✓ Sent to ${reached.length} of ${network.length} relays` : `✗ No relay took it (0 of ${network.length})`}
      </strong>
      {reached.length > 0 && <div class="muted small">{reached.map(r => host(r.url)).join(" · ")}</div>}
      {failed.map(r => <div key={r.url} class="error small">✗ {host(r.url)}: {r.message}</div>)}
      <div class="muted small">✓ Saved to your relay in this browser</div>
      {result.relays.filter(r => r.local).map(r => (
        <div key={r.url} class="muted small">{r.ok ? "✓ Also on this Mac's vault relay" : `This Mac's vault relay (${host(r.url)}) didn't answer. That doesn't change the relays above.`}</div>
      ))}
      <a href="#/profile">See it on your profile</a>
    </div>
  )
}
