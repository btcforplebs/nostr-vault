import { useEffect, useState } from "preact/hooks"
import { getBlocks, loadBlocks, onBlocks } from "../net/blocks.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"

const NONE = { pubkey: null, blocked: new Set(), privateBlocked: new Set(), privateNote: "" }

/** The signed-in user's blocks ({ blocked: Set, privateNote }), loading the list on first use and re-rendering when
 *  it arrives. With no session there is nothing to load, and nothing is hidden. */
export function useBlocks(ctx) {
  const pubkey = ctx.session?.pubkey
  const [blocks, setBlocks] = useState(getBlocks)
  useEffect(() => {
    if (!pubkey) return
    const off = onBlocks(() => setBlocks(getBlocks()))
    const { write = [], read = [] } = ctx.account.relays
    loadBlocks(ctx, uniq([...write, ...read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]))
    setBlocks(getBlocks())
    return off
  }, [pubkey])
  return pubkey && blocks.pubkey === pubkey ? blocks : NONE
}
