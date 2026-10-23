// A key with its Copy button: the Your Keys step of Create an account, and Settings > Your Secret Key.
import { useState } from "preact/hooks"
if (import.meta.env) import("../styles/onboarding.css")

export function KeyCard({ title, caption, value, secret = false }) {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try { await navigator.clipboard.writeText(value); setCopied(true); setTimeout(() => setCopied(false), 1500) } catch {}
  }
  return (
    <section class={secret ? "onboard-card onboard-key secret" : "onboard-card onboard-key"}>
      <div class="onboard-key-head">
        <h2>{title}</h2>
        <button type="button" class="small" onClick={copy} aria-label={`Copy ${title.toLowerCase()}`}>{copied ? "Copied" : "Copy"}</button>
      </div>
      <p>{caption}</p>
      {/* The npub only needs recognising; the nsec has to be readable in full to write it down. */}
      <code class={secret ? "onboard-key-value full" : "onboard-key-value"} translate="no" spellcheck={false}>{value}</code>
      {secret && <p class="onboard-warn">Nobody can recover it for you, not even us.</p>}
    </section>
  )
}
