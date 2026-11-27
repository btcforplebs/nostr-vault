// Your web of trust past your follows, as a hook (moved out of SearchScreen.jsx so other people boxes can rank with it).
import { useEffect, useState } from "preact/hooks"
import { followLists } from "../net/wot.js"
import { vouchesSoon } from "../net/for-you.js"

/** Your web of trust past your follows: the people they follow (wot.js followLists, shared with For you and the Web
 *  tab, so it is asked once a session). Ranks those results after your follows and before everyone else. */
export function useWot(ctx) {
  const [wot, setWot] = useState(() => new Set())
  const follows = ctx.account.follows
  useEffect(() => {
    let live = true
    followLists(ctx.session.pubkey, follows).then(l => vouchesSoon(follows, l)).then(v => live && setWot(new Set(v.keys()))).catch(() => {}) // off the tap, shared with For you (for-you.js)
    return () => { live = false }
  }, [ctx.session.pubkey, follows.length])
  return wot
}
