// The relay page's owner-account box: the account whose notes Haven keeps is set only by signing (owner-proof.js).
// Haven takes its authors at start, so a changed account reloads the page.
import { npubEncode } from "nostr-tools/nip19"
import { loadOwnerAccount, saveOwnerAccount, signWithExtension, signWithKey, bunkerSign } from "./owner-proof.js"

const $ = id => document.getElementById(id)

export function mountAccountProof({ storage, bind, log = () => {}, reload = () => location.reload(), sign = { signWithExtension, signWithKey, bunker: bunkerSign } }) {
  let saved = loadOwnerAccount(storage, { bind, log })
  const say = t => ($("fipsAccountNow").textContent = t)
  say(saved ? `Your notes are kept for ${npubEncode(saved)} (proven by its signature).` : "No account yet: sign once below so your notes are kept. A typed npub can't be used.")
  const take = how => async () => {
    try {
      const proof = await how()
      const k = saveOwnerAccount(proof, storage, { bind })
      $("fipsAccount").value = $("fipsAccountPw").value = ""
      log("fips-owner-account-proven", { same: k === saved })
      if (k !== saved) (saved = k), reload()
    } catch (e) {
      $("fipsAccount").value = $("fipsAccountPw").value = ""
      say(String(e?.message ?? e))
    }
  }
  $("fipsAccountExt").onclick = take(() => sign.signWithExtension(bind))
  $("fipsAccountSign").onclick = take(() => sign.signWithKey($("fipsAccount").value, $("fipsAccountPw").value, bind, { bunker: sign.bunker }))
  $("fipsAccountClear").onclick = () => {
    saveOwnerAccount(null, storage)
    log("fips-owner-account-cleared")
    if (saved) (saved = undefined), reload()
  }
}
