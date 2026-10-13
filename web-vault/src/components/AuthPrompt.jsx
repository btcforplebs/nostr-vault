// The bunker asked the user to approve something on a web page. Shown as a link to tap, not opened for them.
import { useEffect, useState } from "preact/hooks"
import { authUrls, lastAuthUrl, clearAuthUrl } from "../signer/nip46.js"

export function AuthPrompt() {
  const [url, setUrl] = useState(lastAuthUrl)
  useEffect(() => { const f = e => setUrl(e.detail); authUrls.addEventListener("url", f); return () => authUrls.removeEventListener("url", f) }, [])
  if (!url) return null
  return (
    <div class="card auth-prompt">
      <p class="muted small">Your signer wants you to approve this on its web page ({new URL(url).host}).</p>
      <div class="row"><a class="button primary" href={url} target="_blank" rel="noopener noreferrer" onClick={() => { clearAuthUrl(); setUrl("") }}>Open approval page</a></div>
    </div>
  )
}
