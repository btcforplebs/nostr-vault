import { useEffect, useState } from "preact/hooks"
import { getBlocks, loadBlocks, onBlocks } from "../net/blocks.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"

const NONE = { pubkey: null, blocked: new Set(), privateBlocked: new Set(), privateNote: "" }

/** The signed-in user's blocks ({ blocked: Set, privateNote }), loading the list on first use and re-rendering when
 *  it arrives. With no session there is nothing to load, and nothing is hidden. */
export function useBlocks(ctx) {
  const pubkey = ctx.session?.pubkey
  const [blocks, setBlocks] = useState(getBlocks)
  // The account's own relays are often not known yet at sign-in (its kind 10002 comes after): when they arrive, they
  // are asked too, since the list may be on them alone.
  const { write = [], read = [] } = ctx.account?.relays ?? {}
  const relays = uniq([...write, ...read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
  useEffect(() => {
    if (!pubkey) return
    const off = onBlocks(() => setBlocks(getBlocks()))
    loadBlocks(ctx, relays)
    setBlocks(getBlocks())
    return off
  }, [pubkey, relays.join(" ")])
  return pubkey && blocks.pubkey === pubkey ? blocks : NONE
}
