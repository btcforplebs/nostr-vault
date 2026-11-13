// The Media tab's live file notes (RESEARCH/NV_MEDIA_LIVE_FILE_NOTES_PLAN.md, NIP-94 step 4, web read-only): one REQ
// kept open on this browser vault's own /files room, so a note a paired phone writes there shows at once. Only when
// the browser vault is the home vault (Logen's go, option A, 2026-11-12): the web has no websocket over FIPS to reach
// another vault's /files. AUTHed with this browser's mesh key (pair-hello.js sealMeshAuth), never the account key or
// the device key: haven-go files_relay.go refuses every whitelisted key there. The web writes nothing to /files.
import { npubEncode } from "nostr-tools/nip19"
import { FileNotesState, liveFilter } from "./file-notes.js"

/** The relay tag of the /files AUTH: Haven's ServiceURL for the route (haven/vault.js RELAY_HOST). */
export const FILES_AUTH_RELAY = "wss://vault.local/files"
export const FILES_RETRY_MS = 5000

/** havenStart's meshDevices (haven-go SetMeshDevicesC's JSON): this browser's mesh key as self, and each paired device
 *  (the owner set) by npub with the role pairing gave it; "device" for one paired by link. */
export function meshDevicesConfig({ selfHex, owners, devices = [] }) {
  const role = new Map(devices.map(d => [d.hex, d.role]))
  return JSON.stringify({ self: npubEncode(selfHex), devices: [...owners].map(hex => ({ npub: npubEncode(hex), role: role.get(hex) || "device" })) })
}

/**
 * Keeps one REQ open on /files for `owner`'s notes. `onChange(tiles, state)` gets the tiles (FileNotesState.tiles())
 * and the state itself (its emoji copies, net/emoji-notes.js) after each event that changes them. A dropped stream comes back after `retryMs` with `since` (overlap included); a
 * refused AUTH or REQ stops for good (an older vault, a key it doesn't take): no retry loop. -> stop()
 * `haven`: the running vault's haven (conn); none, or no owner, opens nothing. `auth(challenge)` -> signed 22242.
 */
export function watchFileNotes({ haven, owner, auth, onChange, retryMs = FILES_RETRY_MS, timers = { set: setTimeout, clear: clearTimeout }, name = "ui-files-live" }) {
  if (typeof haven?.conn !== "function" || !owner) return () => {}
  const state = new FileNotesState(owner)
  const enc = new TextEncoder()
  let stopped = false, timer = null, conn = null, n = 0

  const open = () => {
    timer = null
    if (stopped) return
    const c = haven.conn(n++ ? `${name}-${n}` : name, { mode: "nip01", route: "/files", owner: true })
    conn = c
    // A refused havenConn is a closed stream with an error string (haven.js): not worth retrying.
    if (c.error) { c.close?.(); conn = null; return }
    const dec = new TextDecoder()
    let buf = "", authID = null, refused = false
    const sub = `files-${n}`
    const send = msg => c.write(enc.encode(JSON.stringify(msg) + "\n"))
    const give = () => { refused = true; c.close() }
    const onLine = line => {
      let m
      try { m = JSON.parse(line) } catch { return }
      if (!Array.isArray(m)) return
      switch (m[0]) {
        case "AUTH":
          Promise.resolve().then(() => auth(m[1])).then(ev => { authID = ev.id; send(["AUTH", ev]) }, give)
          return
        case "OK":
          if (m[1] !== authID) return
          if (!m[2]) return give()
          return send(["REQ", sub, liveFilter(owner, state.since())])
        case "EVENT": {
          if (m[1] !== sub) return
          // A second note for a file already shown changes no tile, but may change whether it is an emoji (Media hides those).
          const before = state.changes
          if (state.apply(m[2]) || state.changes !== before) onChange(state.tiles(), state)
          return
        }
        case "CLOSED":
          if (m[1] === sub) give()
      }
    }
    c.onData(b => {
      buf += dec.decode(b, { stream: true })
      for (let i; (i = buf.indexOf("\n")) >= 0; ) { const line = buf.slice(0, i); buf = buf.slice(i + 1); if (line) onLine(line) }
    })
    c.onClose(() => {
      if (conn === c) conn = null
      if (!stopped && !refused && !timer) timer = timers.set(open, retryMs)
    })
  }
  open()
  return () => {
    stopped = true
    if (timer) timers.clear(timer)
    timer = null
    conn?.close()
  }
}
