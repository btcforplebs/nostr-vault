// Box API, Status area: what the box is running and on. Shapes in api.js.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const statusApi = call => ({
  status: () => call("GET", "status"),
  // The engine's trust ranking status (haven-go vault_status.go, written to the vault folder every 15 s):
  // { status: { state, pausedWhy, accounts: [...] } | null, writtenAt }   signed in
  vaultStatus: () => call("GET", "vault-status"),
})
