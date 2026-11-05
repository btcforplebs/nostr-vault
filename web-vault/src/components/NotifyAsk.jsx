// The notification question, asked once, after you're in (net/first-run.js notifyAction): a card with Turn on, which
// asks the browser from the user's own tap (net/notify-watch.js turnOn), and Not now. Never over the tour (`busy`).
import { useEffect, useRef, useState } from "preact/hooks"
import { NOTIFY_QUESTION, QUIET_MS, markNotifyAsked, notifyAction, notifyAsked } from "../net/first-run.js"
import { permission, turnOn } from "../net/notify-watch.js"
import "../styles/first-run.css"

export function NotifyAsk({ busy }) {
  const [show, setShow] = useState(false)
  const quietSince = useRef(Date.now())
  // The quiet starts again whenever the tour opens or closes: 2 s after it's gone, not 2 s after it began.
  useEffect(() => { quietSince.current = Date.now() }, [busy])
  useEffect(() => {
    const look = () => {
      const a = notifyAction({ permission: permission(), asked: notifyAsked(), inApp: true, busy, quietForMs: Date.now() - quietSince.current })
      if (a === "ask") setShow(true)
      return a !== "wait"
    }
    if (look()) return
    const t = setInterval(() => { if (look()) clearInterval(t) }, 500)
    return () => clearInterval(t)
  }, [busy])
  if (!show || busy) return null
  const answer = async on => { markNotifyAsked(); setShow(false); if (on) await turnOn().catch(() => {}) }
  return (
    <div class="notify-ask" role="dialog" aria-label="Notifications">
      <p>{NOTIFY_QUESTION}</p>
      <div class="notify-ask-actions">
        <button type="button" onClick={() => answer(false)}>Not now</button>
        <button type="button" class="primary" onClick={() => answer(true)}>Turn on</button>
      </div>
    </div>
  )
}
