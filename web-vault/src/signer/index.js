import { extensionSigner } from "./nip07.js"
import { bunkerSigner } from "./nip46.js"
import { readonlySigner } from "./readonly.js"
import { localSigner } from "./local.js"

export function signerFor(session, pool) {
  if (session.method === "nip07") return extensionSigner()
  if (session.method === "nip46") return bunkerSigner(session, pool)
  if (session.method === "readonly") return readonlySigner()
  if (session.method === "local") return localSigner(session)
  throw new Error(`unknown sign-in method ${session.method}`)
}
