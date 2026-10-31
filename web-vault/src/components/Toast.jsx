// Short feedback pills at the top of the screen, as on the iPhone (ActionToastBanner, ZapNotificationBanner): "Liked",
// "Reacted 🔥", "Like failed: …", "Zapping Name 21 sats" then "Zapped Name 21 sats". One pill per key: showing a key
// again replaces its pill (a zap's Zapping becomes Zapped in place; a second like replaces the first "Liked"). A pill
// goes after `seconds` (2.5, or 4 for an error, as ErrorNotificationManager keeps them longer); 0 keeps it until the
// same key is shown again or hidden. It mounts itself on the first show, so no screen has to host it.
import { render } from "preact"
import { useEffect, useState } from "preact/hooks"

if (import.meta.env) import("../styles/toast.css")

let toasts = [] // [{ key, icon, message, tone, label }]
const timers = new Map()
const listeners = new Set()
const emit = () => { for (const f of listeners) f(toasts) }

/** The pills on screen now, oldest first. For the tests. */
export const currentToasts = () => toasts

/** Show or replace the pill for `key`. tone: "accent" (default) | "success" | "error". icon: "heart" | "bolt" | "warn". */
export function showToast({ key = "feedback", message, icon = "heart", tone = "accent", label, seconds }) {
  const toast = { key, icon, message, tone, label: label ?? message }
  toasts = [...toasts.filter(t => t.key !== key), toast]
  clearTimeout(timers.get(key))
  const s = seconds ?? (tone === "error" ? 4 : 2.5)
  if (s > 0) timers.set(key, setTimeout(() => hideToast(key, toast), s * 1000))
  else timers.delete(key)
  mount()
  emit()
  return toast
}

/** Take the pill for `key` away (only `which`, when given, so a newer one under the same key stays). */
export function hideToast(key, which) {
  if (which && !toasts.includes(which)) return
  clearTimeout(timers.get(key)); timers.delete(key)
  const left = toasts.filter(t => t.key !== key)
  if (left.length !== toasts.length) { toasts = left; emit() }
}

let mounted = false
function mount() {
  if (mounted || typeof document === "undefined" || !document.body) return
  mounted = true
  const host = document.createElement("div")
  document.body.appendChild(host)
  render(<Toasts />, host)
}

const ICONS = {
  heart: <path d="M12 20.5S3.5 15.3 3.5 9.2A4.7 4.7 0 0 1 12 6.4a4.7 4.7 0 0 1 8.5 2.8c0 6.1-8.5 11.3-8.5 11.3z" fill="currentColor" />,
  bolt: <path d="M13 2 4 14h7l-1 8 9-12h-7z" fill="currentColor" />,
  warn: <><path d="M12 3 2 21h20z" fill="currentColor" /><path d="M12 10v5M12 18v.01" stroke="#000" stroke-width="2" stroke-linecap="round" /></>,
}

export function Toasts() {
  const [list, setList] = useState(toasts)
  useEffect(() => { listeners.add(setList); setList(toasts); return () => listeners.delete(setList) }, [])
  return (
    <div class="toasts" aria-live="polite">
      {list.map(t => (
        <div key={t.key} class={`toast toast-${t.tone}${t.icon === "bolt" && t.tone === "accent" ? " toast-busy" : ""}`}
          role={t.tone === "error" ? "alert" : "status"} aria-label={t.label}>
          <svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">{ICONS[t.icon] ?? ICONS.heart}</svg>
          <span>{t.message}</span>
        </div>
      ))}
    </div>
  )
}
