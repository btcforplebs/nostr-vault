import { useState } from "preact/hooks"
import { useProfile } from "./useProfile.js"

/** Round avatar; `ring` draws the accent ring (profile header, active Profile tab). */
export function Avatar({ pubkey, size = 40, ring = false }) {
  const p = useProfile(pubkey)
  // Remember which URL failed, not just "failed": a newer kind 0 with a working picture must get its chance.
  const [broken, setBroken] = useState("")
  const style = { width: size, height: size }
  const cls = ring ? "avatar ring" : "avatar"
  if (p?.picture && broken !== p.picture) return <img class={cls} style={style} src={p.picture} alt="" loading="lazy" onError={() => setBroken(p.picture)} />
  return <div class={cls + " avatar-blank"} style={{ ...style, background: `hsl(${parseInt(pubkey.slice(0, 6), 16) % 360} 45% 35%)` }} />
}
