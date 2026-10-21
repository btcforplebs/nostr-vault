// This browser keeps a copy of the vault, and the browser may clear it. After sign-in we ask it to keep the copy.
// The phone's vault is the real one.

// The browser's answer to navigator.storage.persist(): true (kept), false (may clear it), or null (it can't be asked).
export async function askToKeep(storage = globalThis.navigator?.storage) {
  if (typeof storage?.persist !== "function") return null
  try { return (await storage.persist()) === true } catch { return false }
}

// `kept` is that answer; leave it out (undefined) when it isn't known yet, as on the sign-in screen.
export function StorageNote({ kept }) {
  return (
    <div class="storage-note">
      <p class="muted small">This browser keeps a copy of your notes, and the browser can clear it. Your phone's vault is the real one.</p>
      {kept !== undefined && <p class={`storage-kept small ${kept ? "on" : ""}`}>{kept ? "Kept on this browser" : "This browser may clear it"}</p>}
    </div>
  )
}
