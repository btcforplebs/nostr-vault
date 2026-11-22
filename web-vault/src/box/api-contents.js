// Box API, Contents area (One Vault E4, haven-go/internal/box/routes_contents.go and routes_logs.go):
//   GET contents     -> { vaultDir, measuredAt, disk, split: { database, media, other }, media: { count, size, buckets } }
//                       media is the browser's scanMedia shape (net/vault-contents.js); any signed-in account
//   GET connections  -> { open, byRoute: { "/": n, "/private": n, ... } }      relay sockets open through the box
//   GET logs?after=&limit= -> { lines: [{ seq, at (unix s), source: "engine" | "box", text }], last, dropped? }
//                       first account only; without after, the newest lines
// Note counts aren't here: the dashboard counts through the box's relay (NIP-45 COUNT) as the signed-in account.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const contentsApi = call => ({
  contents: () => call("GET", "contents"),
  connections: () => call("GET", "connections"),
  logs: (after = 0) => call("GET", after > 0 ? `logs?after=${after}&limit=1000` : "logs?limit=1000"),
})
