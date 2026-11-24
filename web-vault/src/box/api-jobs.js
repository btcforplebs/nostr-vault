// Box API, Jobs area (One Vault E5, haven-go/internal/box/routes_jobs.go, routes_access.go, routes_backup.go):
//   GET  imports                 -> the engine's import_jobs.json ({ account, start_date, jobs: [...] }, as import-jobs.js)   signed in
//   POST imports/run|cancel      { job } -> { asked, answered, code, message }   code: run 0 started, 1 unknown, 2 busy, 3 not ready
//   GET  trust                   -> { trust: { running, phase, found, size, ... }, last }                                     signed in
//   POST trust/refresh           -> { asked, answered, code, message }                                                        signed in
//   GET  blocklist               -> { npubs }                                                                                 signed in
//   POST blocklist               { npubs } -> { npubs, blocked?, answered }                                                   first account
//   GET  backups                 -> { backups: [{ name, size, createdAt }], job? }                                            first account
//   POST backups/now             -> 202 job { kind, name, phase, error?, startedAt, finishedAt? }                             first account
//   POST backups/restore         { name } -> 202 job                                                                          first account
//   POST restart                 -> 202 job                                                                                   first account
// job.phase: stopping, working, starting, done, failed. 409 while another backup, restore, restart or a Move runs.
/** `call`: api.js's signed caller, (method, name, payload) -> data. */
export const jobsApi = call => ({
  imports: () => call("GET", "imports"),
  runImport: job => call("POST", "imports/run", { job }),
  cancelImport: job => call("POST", "imports/cancel", { job }),
  trust: () => call("GET", "trust"),
  refreshTrust: () => call("POST", "trust/refresh", {}),
  blocklist: () => call("GET", "blocklist"),
  setBlocklist: npubs => call("POST", "blocklist", { npubs }),
  backups: () => call("GET", "backups"),
  backupNow: () => call("POST", "backups/now", {}),
  restore: name => call("POST", "backups/restore", { name }),
  restart: () => call("POST", "restart", {}),
})
