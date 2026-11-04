// Picture-in-picture for a <video> (PiP plan lane D, RESEARCH/NV_PIP_PLAN.md): the browser floats it in its own
// window, over other tabs and apps. Chrome, Edge and Safari have the API; where it is missing (Firefox) or turned off,
// there is no button. A second tap brings the video back.
import { useEffect, useState } from "preact/hooks"
import { canPiP, togglePiP } from "./pip.js"

const PIP = "M19 7h-8v6h8V7zm2-4H3c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H3V5h18v14z"

/** The button, over the video `target` (a ref) points at. */
export function PipButton({ target, class: cls = "pip-button" }) {
  const [able, setAble] = useState(false)
  const [active, setActive] = useState(false)
  const [err, setErr] = useState("")
  useEffect(() => {
    const video = target.current
    if (!video) return
    setAble(canPiP(video))
    const on = () => setActive(true), off = () => setActive(false)
    video.addEventListener("enterpictureinpicture", on)
    video.addEventListener("leavepictureinpicture", off)
    return () => { video.removeEventListener("enterpictureinpicture", on); video.removeEventListener("leavepictureinpicture", off) }
  }, [target.current])
  if (!able) return null
  const label = active ? "Back from picture in picture" : "Picture in picture"
  return (
    <button type="button" class={cls} aria-label={label} title={err || label} aria-pressed={active}
      onClick={() => { setErr(""); togglePiP(target.current)?.catch?.(e => setErr(String(e?.message ?? e))) }}>
      <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true"><path d={PIP} /></svg>
    </button>
  )
}
