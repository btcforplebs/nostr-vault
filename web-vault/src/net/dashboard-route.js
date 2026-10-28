// Where the Vault Dashboard sheet (screens/VaultDashboard.jsx) is open: "?sheet=dashboard" on any address, so Back
// closes it, a link in it leaves it, and the screen under it stays as it was.
import { withParam, parseHash } from "../desktop/routes.js"

export const SHEET = "dashboard"
/** The address that opens the dashboard over `hash`. */
export const dashboardHref = (hash = globalThis.location?.hash ?? "") => withParam(hash || "#/vault", "sheet", SHEET)
export const isDashboardOpen = (hash = globalThis.location?.hash ?? "") => parseHash(hash).params.get("sheet") === SHEET
/** Done: back where it was opened from, or the same address without the sheet. */
export function closeDashboard() {
  if (history.state?.nvSheet) history.back()
  else location.replace(withParam(location.hash, "sheet", null))
}
export function openDashboard() {
  if (isDashboardOpen()) return
  history.pushState({ nvSheet: true }, "", dashboardHref())
  dispatchEvent(new HashChangeEvent("hashchange"))
}
