import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { useProfile } from "./useProfile.js"

export function ProfileHeader({ pubkey, follows }) {
  const p = useProfile(pubkey)
  const npub = npubEncode(pubkey)
  return (
    <header class="profile-header">
      {p?.banner ? <img class="banner" src={p.banner} alt="" /> : <div class="banner" />}
      <div class="profile-id">
        <Avatar pubkey={pubkey} size={72} />
        <div>
          <h1>{p?.name || npub.slice(0, 16) + "…"}</h1>
          {p?.nip05 && <div class="muted">{p.nip05}</div>}
          <div class="muted mono">{npub.slice(0, 20)}…</div>
        </div>
      </div>
      {p?.about && <p class="about">{p.about}</p>}
      <div class="muted">{follows} following</div>
    </header>
  )
}
