import { useState } from "preact/hooks"
import { useProfile } from "./useProfile.js"

export function Avatar({ pubkey, size = 40 }) {
  const p = useProfile(pubkey)
  const [broken, setBroken] = useState(false)
  const style = { width: size, height: size }
  if (p?.picture && !broken) return <img class="avatar" style={style} src={p.picture} alt="" loading="lazy" onError={() => setBroken(true)} />
  return <div class="avatar avatar-blank" style={{ ...style, background: `hsl(${parseInt(pubkey.slice(0, 6), 16) % 360} 45% 35%)` }} />
}
