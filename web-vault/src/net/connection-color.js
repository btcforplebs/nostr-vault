// The Vault button's colour, by the iPhone's rule (NostrService+Connection connectionColor): the app's own relay
// connections. Any connected: green "Connected". Otherwise any connecting: yellow "Connecting...", and a drop from
// green waits 2 s before it shows. Otherwise a failed one (or the browser is offline): red "Connection Error".
// Otherwise grey "Disconnected".

export const STATES = {
  connected: { color: "#30d158", text: "Connected" },
  connecting: { color: "#ffd60a", text: "Connecting..." },
  error: { color: "#ff453a", text: "Connection Error" },
  disconnected: { color: "#8e8e93", text: "Disconnected" },
}
export const DROP_GRACE_MS = 2000

/** The state from the pool (LivePool: `relays` Map of relays with `connected`, `closing` Set of failed ones). */
export function poolState(pool, online = globalThis.navigator?.onLine !== false) {
  const relays = [...(pool?.relays?.values?.() ?? [])]
  if (relays.some(r => r?.connected)) return "connected"
  if (!online) return "error"
  if (relays.length) return "connecting"
  if (pool?.closing?.size) return "error"
  return "disconnected"
}

/** Applies the 2 s grace: a drop from connected to connecting keeps showing connected until it has lasted 2 s.
 *  `prev` is this function's last answer. -> { shown, dropAt } */
export function withGrace(prev, next, now = Date.now()) {
  if (next === "connected") return { shown: "connected", dropAt: null }
  if (prev?.shown === "connected" && next === "connecting") {
    const dropAt = prev.dropAt ?? now
    if (now - dropAt < DROP_GRACE_MS) return { shown: "connected", dropAt }
  }
  return { shown: next, dropAt: null }
}
