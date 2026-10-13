import { extensionSigner } from "./nip07.js"
import { bunkerSigner } from "./nip46.js"

export function signerFor(session, pool) {
  if (session.method === "nip07") return extensionSigner()
  if (session.method === "nip46") return bunkerSigner(session, pool)
  throw new Error(`unknown sign-in method ${session.method}`)
}
