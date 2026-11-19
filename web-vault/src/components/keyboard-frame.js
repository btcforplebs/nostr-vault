// The visible area while an on-screen keyboard is up, for screens that pin something to it (ComposeScreen.jsx).
import { useEffect, useState } from "preact/hooks"

// An on-screen keyboard shrinks only the visual viewport, so 100vh can't see it, and iOS Safari scrolls the page to
// the caret instead: the sheet's bar went up under the status bar and the tools down under the keyboard. While a
// keyboard is up, the sheet is pinned to what's visible. Zoom shrinks the visual viewport too, so the keyboard is
// what's left of the layout viewport once zoom is cancelled (height * scale).
const KEYBOARD_MIN = 120
export function keyboardFrame(vv, layoutHeight) {
  if (!vv || layoutHeight - vv.height * vv.scale < KEYBOARD_MIN) return null
  return { top: vv.offsetTop, height: vv.height }
}

export function useKeyboardFrame(on) {
  const [frame, setFrame] = useState(null)
  useEffect(() => {
    const vv = globalThis.visualViewport
    if (!on || !vv) return
    const update = () => setFrame(f => {
      const next = keyboardFrame(vv, document.documentElement.clientHeight)
      return f?.top === next?.top && f?.height === next?.height ? f : next
    })
    update()
    vv.addEventListener("resize", update)
    vv.addEventListener("scroll", update)
    return () => { vv.removeEventListener("resize", update); vv.removeEventListener("scroll", update) }
  }, [on])
  return frame
}
