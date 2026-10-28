// "Who can reach you" (VaultDashboardView reachSection): the trust list and Blocked. The web's trust list is the
// people your follows follow (notifications.js trustedWeb), two hops. The phone's relay-list row is left out: the
// browser's relay has no address for other apps to find.
import { Row, Section } from "./parts.jsx"

export const WEB_HOPS = 2
export const blockedDetail = n => (n === 0 ? "Nobody blocked." : n === 1 ? "1 person blocked." : `${n} people blocked.`)

export function ReachSection({ trusted = 0, blocked = 0 }) {
  return (
    <Section title="Who can reach you">
      <Row icon="crowd" href="#/wot"
        title={trusted ? `${trusted.toLocaleString()} people can reach your inbox` : "Trust list not built yet"}
        detail={`People within ${WEB_HOPS} hops of you. Everyone else is kept out.`} />
      <Row icon="hand" title="Blocked" detail={blockedDetail(blocked)} href="#/settings/blocked" />
    </Section>
  )
}
