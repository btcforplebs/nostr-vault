// Box API, Accounts area (One Vault addendum A.3): the accounts a box holds. Shapes (haven-go/internal/box/routes_accounts.go):
//   GET  accounts         -> { accounts: [{ npub, state, added?, name? }] }   first account only; the first account is first
//   GET  accounts/me      -> { npub, state }                                  anyone who signs: does this box hold me
//   POST accounts/code    -> { code, expiresAt: unix seconds }                first account only; one use, 15 minutes
//   POST accounts/join    { code, name? } -> { npub, state, added?, name?, already? }  anyone who signs, with a code
//   POST accounts/remove  { npub } -> { removed, kept }                       first account only; notes and files stay
// state: "first" | "signedIn" | "watchOnly" | "none".
// Its own signed caller, not api.js's: there every 401/403 reads "only the box's owner", but here a 403 can be a wrong
// join code, and me/join are for accounts that aren't the owner. The box's own words are shown as they come.
import { nip98Header } from "./api.js"
import { boxApiBase } from "./mode.js"

export const STATE_LABEL = { first: "First account", signedIn: "Signed in", watchOnly: "Watch-only", none: "Not on this box" }

/** `signer`: the signed-in account's ({ signEvent }); `fetchImpl`: fetch (a mock in tests). */
export function accountsApi({ signer, base = boxApiBase(), fetchImpl = (...a) => fetch(...a) }) {
  const call = async (method, name, payload) => {
    if (!signer?.signEvent || signer.readOnly) throw new Error("Sign in with your account's signer to use the box.")
    const url = `${base}/${name}`
    const body = payload ? JSON.stringify(payload) : undefined
    const headers = { Authorization: await nip98Header(signer, url, method, payload) }
    if (body) headers["Content-Type"] = "application/json"
    const res = await fetchImpl(url, { method, headers, body })
    const text = await res.text()
    let data = null
    try { data = text ? JSON.parse(text) : null } catch {}
    if (!res.ok) {
      const said = data?.message || data?.error
      const e = new Error(res.status === 401 ? `The box didn't accept this sign-in${said ? ` (${said})` : ""}. Check your signer and the time on this device.`
        : said ? said[0].toUpperCase() + said.slice(1) : `The box answered ${res.status}`)
      e.status = res.status // 403 on a first-account route: this account doesn't run the box
      throw e
    }
    return data ?? {}
  }
  return {
    list: () => call("GET", "accounts").then(d => (Array.isArray(d.accounts) ? d.accounts : [])),
    me: () => call("GET", "accounts/me"),
    code: () => call("POST", "accounts/code", {}),
    join: (code, name = "") => call("POST", "accounts/join", { code, ...(name.trim() && { name: name.trim() }) }),
    remove: npub => call("POST", "accounts/remove", { npub }),
  }
}
