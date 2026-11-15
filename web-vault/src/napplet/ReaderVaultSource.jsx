// The Reader's Vault source (reader-vault.js): mounted while the desktop shows a Vault list page. It runs the Vault
// screen's own useVault and keeps the latest in `pipe`, with the controls the Reader's intents use. Renders nothing.
import { useEffect, useRef, useState } from "preact/hooks"
import { useVault } from "../screens/VaultScreen.jsx"
import { useVaultSearch } from "../screens/VaultSearch.jsx"
import { onProfiles } from "../net/profiles.js"

export function ReaderVaultSource({ ctx, mode, pipe }) {
  const root = useRef(null) // nothing to hold: the Reader keeps its own scroll
  const v = useVault(ctx, root)
  const s = useVaultSearch(ctx) // the Vault's search (step 8b): walks nothing until the Reader sends words
  const [tick, setTick] = useState(0)
  useEffect(() => { let t = null; const off = onProfiles(() => { if (!t) t = setTimeout(() => { t = null; setTick(n => n + 1) }, 500) }); return () => { off(); clearTimeout(t) } }, [])
  // The page in the address is the page shown (#/vault/<mode>).
  useEffect(() => { if (mode && mode !== v.mode) v.pick(mode) }, [mode])
  pipe.ctl = { mode: () => v.mode, choose: v.choose, more: () => v.onMore(v.shown >= v.items.length), find: (text, now) => (now || !text.trim() ? s.now(text) : s.setText(text)) }
  useEffect(() => { pipe.put({ ...v, search: { text: s.text, found: s.found, busy: s.busy } }) }, [v.mode, v.filter, v.items, v.shown, v.notes, v.status, v.loaded, v.ready, v.paging, v.older, v.fresh.size, [...v.fresh].join(), tick, s.text, s.found, s.busy])
  useEffect(() => () => { pipe.ctl = null; pipe.put(null) }, [])
  return null
}
