// The Feed Dashboard's "Your vault" line: how many events this browser's vault holds, summed over the routes the Vault
// Dashboard counts (vault-contents.js COUNT_ROUTES). Asked of the in-page Haven only; nothing leaves the page.
import { routeClient, deviceKey } from "../haven/vault.js"
import { COUNT_ROUTES } from "./vault-contents.js"

/** -> the total, or null when a route didn't answer. */
export async function countEvents(vault) {
  const sk = deviceKey(), clients = COUNT_ROUTES.map(r => routeClient(vault.haven, r, sk, `fdash${r.replace("/", "-")}`))
  try {
    const counts = await Promise.all(clients.map(c => c.count({})))
    return counts.every(Number.isFinite) ? counts.reduce((a, b) => a + b, 0) : null
  } catch { return null } finally { for (const c of clients) c.close() }
}
