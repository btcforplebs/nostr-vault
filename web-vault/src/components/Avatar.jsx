import { useState } from "preact/hooks"
import { useProfile } from "./useProfile.js"
import { useSmallSrc } from "./small-image.js"

/** Round avatar; `ring` draws the accent ring (profile header, active Profile tab). `load` false: the blank disc
 *  only, so a stranger's picture host (any server they name in their kind 0) learns nothing when it draws. */
export function Avatar({ pubkey, size = 40, ring = false, load = true }) {
  const p = useProfile(pubkey)
  // Remember which URL failed, not just "failed": a newer kind 0 with a working picture must get its chance.
  const [broken, setBroken] = useState("")
  const style = { width: size, height: size }
  const cls = ring ? "avatar ring" : "avatar"
  const pic = load && p?.picture && broken !== p.picture ? p.picture : null
  // Drawn at its own size, not the original's (a GIF as a still that plays on hover): small-image.js.
  const small = useSmallSrc(pic, { box: { w: size, h: size }, fit: "cover" })
  if (pic && !small.ready) return <div ref={small.ref} class={cls} style={style} />
  if (pic) return <img ref={small.ref} class={cls} style={style} src={small.src} alt="" loading="lazy" onError={() => setBroken(pic)} {...small.hover} />
  return <div class={cls + " avatar-blank"} style={{ ...style, background: `hsl(${parseInt(pubkey.slice(0, 6), 16) % 360} 45% 35%)` }} />
}
