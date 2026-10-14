// Someone else's profile (opened from Search): their kind 0 from Haven, else the network. Their notes aren't
// loaded here yet; ProfileScreen reads only the user's own outbox.
import { useEffect } from "preact/hooks"
import { ProfileHeader } from "../components/ProfileHeader.jsx"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"

export function PersonScreen({ ctx, pubkey }) {
  useEffect(() => { fetchProfiles(ctx.vault, [pubkey], uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])).catch(() => {}) }, [pubkey])
  return (
    <main class="screen">
      <ProfileHeader pubkey={pubkey} you={false} />
      <p class="empty">Their notes aren't shown here yet.</p>
    </main>
  )
}
