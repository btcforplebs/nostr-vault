import { useState } from "preact/hooks"
import { useProfile } from "./useProfile.js"

/** Round avatar; `ring` draws the accent ring (profile header, active Profile tab). `load` false: the blank disc
 *  only, so a stranger's picture host (any server they name in their kind 0) learns nothing when it draws. */
export function Avatar({ pubkey, size = 40, ring = false, load = true }) {
  const p = useProfile(pubkey)
  // Remember which URL failed, not just "failed": a newer kind 0 with a working picture must get its chance.
  const [broken, setBroken] = useState("")
  const style = { width: size, height: size }
  const cls = ring ? "avatar ring" : "avatar"
  if (load && p?.picture && broken !== p.picture) return <img class={cls} style={style} src={p.picture} alt="" loading="lazy" onError={() => setBroken(p.picture)} />
  return <div class={cls + " avatar-blank"} style={{ ...style, background: `hsl(${parseInt(pubkey.slice(0, 6), 16) % 360} 45% 35%)` }} />
}
