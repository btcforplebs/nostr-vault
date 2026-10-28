import { useEffect, useState } from "preact/hooks"
import { getVaultUnread, onVaultUnread } from "../net/notify-watch.js"

/** Unread Vault lines (notify-watch.js), for the Vault tab's dot beside unread messages (the iPhone's vaultHasNews). */
export function useVaultUnread() {
  const [n, setN] = useState(getVaultUnread)
  useEffect(() => onVaultUnread(() => setN(getVaultUnread())), [])
  return n
}
