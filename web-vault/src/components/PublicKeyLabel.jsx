// "Key is public": shown on the profile of an account whose secret key a loaded profile published
// (net/secret-key-leak.js). Anyone can sign as it, so the web gate keeps it outside.
import { useEffect, useState } from "preact/hooks"
import { PUBLIC_KEY_LABEL, isPublicKeyAccount, onPublicKeys } from "../net/secret-key-leak.js"

export function usePublicKey(pubkey) {
  const [pub, setPub] = useState(() => isPublicKeyAccount(pubkey))
  useEffect(() => {
    setPub(isPublicKeyAccount(pubkey))
    return onPublicKeys(() => setPub(isPublicKeyAccount(pubkey)))
  }, [pubkey])
  return pub
}

export function PublicKeyLabel({ pubkey }) {
  return usePublicKey(pubkey) ? <p class="public-key-label" role="note">{PUBLIC_KEY_LABEL}</p> : null
}
