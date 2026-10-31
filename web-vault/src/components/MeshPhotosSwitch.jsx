// Settings › Media Servers: the one switch for photos over the FIPS mesh (fips-media.js). On by default; only notes
// from you or people you follow use the mesh even when it is on. Saved in this browser.
import { useState } from "preact/hooks"
import { meshPhotosOn, setMeshPhotosOn } from "../net/fips-media.js"

export function MeshPhotosSwitch() {
  const [on, setOn] = useState(meshPhotosOn)
  const flip = e => { const v = e.currentTarget.checked; setMeshPhotosOn(v); setOn(v) }
  return (
    <>
      <label class="settings-row static mesh-photos-switch">
        <span class="settings-title">Load photos over the mesh</span>
        <input type="checkbox" role="switch" checked={on} onChange={flip} />
      </label>
      <p class="settings-note muted small">When a photo is on a mesh vault, or its server is down and the author lists a mesh vault, this browser fetches it over the mesh with a throwaway key. Only for your notes and people you follow.</p>
    </>
  )
}
