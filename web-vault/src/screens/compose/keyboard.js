// Reply opens with the keyboard up and the cursor in the box, as on the iPhone. Mobile Safari (and Chrome on Android
// for the soft keyboard) only raise the keyboard for a focus() made inside the tap itself, but Compose mounts after the
// hash change, a frame later. So the tap focuses a hidden stand-in field at once ([primeKeyboard]), and Compose moves
// the focus into its own box when it mounts ([takeKeyboard]); moving focus between fields keeps the keyboard up.

let primer = null
let timer = null

/** Call inside the tap. Focuses an invisible field so the keyboard starts coming up now. */
export function primeKeyboard(doc = globalThis.document) {
  if (!doc?.body || primer) return
  const el = doc.createElement("input")
  el.setAttribute("aria-hidden", "true")
  el.tabIndex = -1
  // 16px so iOS doesn't zoom the page to it; on screen (not off-left) so Safari doesn't scroll to find it.
  el.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;border:0;padding:0;font-size:16px;pointer-events:none"
  doc.body.append(el)
  el.focus({ preventScroll: true })
  primer = el
  // Compose never took it (the note wasn't found, the route changed): let the keyboard go.
  timer = setTimeout(release, 2000)
}

/** Compose's box takes the focus (and the keyboard) with the cursor at the end, then the stand-in goes. */
export function takeKeyboard(box) {
  if (box) {
    box.focus({ preventScroll: true })
    const end = box.value?.length ?? 0
    box.setSelectionRange?.(end, end)
  }
  release()
}

function release() {
  clearTimeout(timer); timer = null
  primer?.remove(); primer = null
}
