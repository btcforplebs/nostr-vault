// The camera reading a pairing code (plan §5). The browser asks for the camera only when this opens; with no camera,
// no permission, or no way to decode, `onUnavailable(why)` ("noCamera" | "denied") so the screen offers the check
// words or "Show my code instead". Every track stops when it closes.
import { useEffect, useRef, useState } from "preact/hooks"
import { pickDecoder, onceEach } from "./qr-decode.js"

const EVERY_MS = 250

export function QrReader({ onCode, onUnavailable, label = "Camera, looking for a pairing code" }) {
  const video = useRef(null)
  const handlers = useRef({ onCode, onUnavailable })
  handlers.current = { onCode, onUnavailable }
  const [live, setLive] = useState(false)
  useEffect(() => {
    let stopped = false, stream = null, timer = null
    const pass = onceEach(text => handlers.current.onCode?.(text))
    const fail = why => { if (!stopped) handlers.current.onUnavailable?.(why) }
    ;(async () => {
      if (!navigator.mediaDevices?.getUserMedia) return fail("noCamera")
      try {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false })
      } catch (e) {
        return fail(e?.name === "NotAllowedError" || e?.name === "SecurityError" ? "denied" : "noCamera")
      }
      if (stopped) return stream.getTracks().forEach(t => t.stop())
      const v = video.current
      v.srcObject = stream
      await v.play().catch(() => {})
      let reader
      try { reader = await pickDecoder() } catch { return fail("noCamera") }
      if (stopped) return
      setLive(true)
      const tick = async () => {
        if (stopped) return
        try { pass(await reader.decode(v)) } catch {}
        if (!stopped) timer = setTimeout(tick, EVERY_MS)
      }
      tick()
    })()
    return () => {
      stopped = true
      clearTimeout(timer)
      stream?.getTracks().forEach(t => t.stop())
    }
  }, [])
  return (
    <div class="pair-camera" aria-busy={!live || undefined}>
      <video ref={video} muted playsInline aria-label={label} />
      {!live && <p class="muted small">Starting the camera…</p>}
    </div>
  )
}
