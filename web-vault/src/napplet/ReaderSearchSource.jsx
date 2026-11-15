// The Reader's Search source (reader-search.js): mounted while the desktop shows Search. It runs the Search screen's
// own hooks and keeps the latest in `pipe`, with the controls the Reader's intents use. Renders nothing.
import { useEffect, useState } from "preact/hooks"
import { useSearch } from "../screens/SearchScreen.jsx"
import { useSearchStart } from "../screens/SearchStart.jsx"
import { clearRecent } from "../net/search.js"
import { onProfiles } from "../net/profiles.js"

export function ReaderSearchSource({ ctx, pipe }) {
  const search = useSearch(ctx)
  const start = useSearchStart(ctx, search.blocked)
  const [tick, setTick] = useState(0)
  useEffect(() => { let t = null; const off = onProfiles(() => { if (!t) t = setTimeout(() => { t = null; setTick(n => n + 1) }, 500) }); return () => { off(); clearTimeout(t) } }, [])
  pipe.ctl = { setText: search.setText, setFilter: search.setFilter, submit: search.submit, clear: search.clear, forget: () => search.setRecent(clearRecent(globalThis.localStorage)) }
  useEffect(() => { pipe.put({ search, start, recent: search.recent }) },
    [search.text, search.found, search.sources, search.finished, search.filter, search.recent, search.shown, start.trending.join(), start.active.join(), start.forYou, start.liveStreams, tick])
  useEffect(() => () => { pipe.ctl = null; pipe.put(null) }, [])
  return null
}
