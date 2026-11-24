// Box API, Devices area: the box and the owner's devices, two-scan pairing and Remove (haven-go internal/box
// routes_devices.go, routes_pairing.go). Shapes:
//   GET  devices        -> { box: { npub, name, approved, address }, devices: [{ npub, pubkey, name, role, approved,
//                           vouchedBy, pairedAt }], paired, hint, lists }   paired: the box's own paired set decides
//                           (Remove works); false while the owner's media server lists still do
//   POST devices/remove { npub } -> { removed, devices }                   409 while the lists still decide
//   GET  pair           -> { state, code, box: { npub }, startedAt, expiresAt, device: { npub, name, role }, words: [4
//                           BIP-39 indexes], confirmText, refusal, acked, error }
//                           state: idle | waiting | hello | linked | expired | aborted | busy (another account's run)
//   POST pair           -> the same; 409 while another account's pairing is live
//   POST pair/confirm   { role } -> the same; 409 when nothing waits or the role is not the one shown, 503 when the
//                           box's mesh is away or no relay took the answer (error says so)
//   POST pair/cancel    -> the same
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const devicesApi = call => ({
  devices: () => call("GET", "devices"),
  removeDevice: npub => call("POST", "devices/remove", { npub }),
  pairStatus: () => call("GET", "pair"),
  pairStart: () => call("POST", "pair"),
  pairConfirm: role => call("POST", "pair/confirm", { role }),
  pairCancel: () => call("POST", "pair/cancel"),
})
