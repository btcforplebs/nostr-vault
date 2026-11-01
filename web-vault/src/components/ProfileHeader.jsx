import { useEffect, useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { Avatar } from "./Avatar.jsx"
import { Badges } from "./Badges.jsx"
import { useProfile } from "./useProfile.js"
import { fetchFollowers, keptFollowers } from "../net/followers.js"
import { MediaLightbox } from "./MediaLightbox.jsx"
import { imageItem } from "../net/note-media.js"
import { NoteText } from "./NoteText.jsx"

if (import.meta.env) import("../styles/profile.css")

/** The iOS profile header (ProfileContent+Header): banner a third of the width fading to black, a 72 ringed avatar
 *  half over it, name + the seal (on a NIP-05, as on note rows and the iPhone) with the YOU / MUTUAL / FOLLOWING /
 *  FOLLOWS YOU badge at the right edge, bio, chips, counts, then `children` (Edit Profile or Follow, and WoT).
 *  Followers is asked for after the header is drawn (net/followers.js) and shows "—" until a relay counts it. */
export function ProfileHeader({ pubkey, follows, you = true, relation = "", children }) {
  const p = useProfile(pubkey)
  const followers = useFollowers(pubkey)
  const npub = npubEncode(pubkey)
  // Offline, the banner URL fails: drop the img so the gradient shows, not a broken-image icon. Keyed on the URL so a newer one gets its chance.
  const [badBanner, setBadBanner] = useState("")
  // profiles.js keeps website only as an http(s) URL, so it goes into href as-is.
  const site = p?.website?.replace(/^https?:\/\//, "").replace(/\/$/, "")
  // A tap on the picture or the banner opens it full size (ProfileSupport); a tap on the npub or lightning chip copies
  // it and says so for two seconds (ProfileContent+Header).
  const [full, setFull] = useState(null) // the URL open full size
  const [copied, setCopied] = useState("") // "npub" | "ln"
  const copy = (what, text) => navigator.clipboard?.writeText(text).then(() => { setCopied(what); setTimeout(() => setCopied(c => (c === what ? "" : c)), 2000) }).catch(() => {})
  return (
    <header class="profile-header">
      <div class="banner">{p?.banner && badBanner !== p.banner && (
        <button type="button" class="banner-open" aria-label="Open the banner full size" onClick={() => setFull(p.banner)}><img src={p.banner} alt="" onError={() => setBadBanner(p.banner)} /></button>
      )}</div>
      <div class="profile-id">
        {p?.picture
          ? <button type="button" class="avatar-open" aria-label="Open the picture full size" onClick={() => setFull(p.picture)}><Avatar pubkey={pubkey} size={72} ring /></button>
          : <Avatar pubkey={pubkey} size={72} ring />}
        <div class="profile-names">
          <div class="profile-name-row">
            <h1>{p?.display_name || p?.name || npub.slice(0, 16) + "…"}</h1>
            <Badges pubkey={pubkey} />
            <span class="profile-badge">{you ? <span class="you-badge">YOU</span> : <Relation kind={relation} />}</span>
          </div>
          {p?.nip05 && <div class="profile-nip05">{p.nip05.replace(/^_@/, "")}</div>}
        </div>
      </div>
      {/* The bio reads like a note: nostr:npub as @name, links as links (NoteText). Quotes stay short references
          (depth 1) and pictures wait for a tap, so a stranger's bio can't fill the header. */}
      {p?.about && <div class="about"><NoteText content={p.about} depth={1} images={false} memoryOnly={!you} /></div>}
      <div class="chips">
        {p?.lud16 && <button class={`chip chip-ln${copied === "ln" ? " copied" : ""}`} type="button" title="Copy lightning address" onClick={() => copy("ln", p.lud16)}>
          {copied === "ln" ? <Icon d={CHECK} /> : <Icon d="M13 2L4 14h7l-1 8 9-12h-7z" fill />}{copied === "ln" ? "Copied" : p.lud16}</button>}
        {site && <a class="chip" href={p.website} target="_blank" rel="noopener noreferrer"><Icon d="M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z" />{site}</a>}
        <button class={`chip${copied === "npub" ? " copied" : ""}`} type="button" title="Copy npub" onClick={() => copy("npub", npub)}>
          {copied === "npub" ? <Icon d={CHECK} /> : <Icon d="M15 7a4 4 0 1 0-3.9 4.9L4 19v2h3v-2h2v-2h2l1.4-1.4" />}{copied === "npub" ? "Copied" : `${npub.slice(0, 12)}…${npub.slice(-7)}`}</button>
      </div>
      <div class="counts"><span><b>{follows != null ? fmt(follows) : "—"}</b> Following</span><span><b>{followers != null ? fmt(followers) : "—"}</b> Followers</span></div>
      {children}
      {full && <MediaLightbox items={[imageItem(full)]} author={pubkey} onClose={() => setFull(null)} />}
    </header>
  )
}

// As PersonProfileView.badge: MUTUAL in the verified teal with its ∞, else FOLLOWING (green) and/or FOLLOWS YOU (grey).
function Relation({ kind }) {
  if (kind === "mutual") return <span class="rel-badge mutual"><b aria-hidden="true">∞</b>MUTUAL</span>
  if (kind === "following") return <span class="rel-badge following">FOLLOWING</span>
  if (kind === "follows-you") return <span class="rel-badge follows-you">FOLLOWS YOU</span>
  return null
}

/** The relays' Followers count for pk, filled in once they answer; a count kept from a recent open shows at once. */
function useFollowers(pk) {
  const [n, setN] = useState(() => keptFollowers(pk) ?? null)
  useEffect(() => {
    const kept = keptFollowers(pk)
    setN(kept ?? null)
    if (kept != null) return
    let live = true
    fetchFollowers(pk, c => { if (live) setN(c) })
    return () => { live = false }
  }, [pk])
  return n
}

const fmt = n => n >= 1e6 ? short(n / 1e6) + "M" : n >= 1000 ? short(n / 1000) + "k" : String(n)
const short = x => x.toFixed(1).replace(/\.0$/, "")

const CHECK = "M5 12.5l4.5 4.5L19 7"
const Icon = ({ d, fill }) => (
  <svg viewBox="0 0 24 24" width="14" height="14" fill={fill ? "currentColor" : "none"} stroke={fill ? "none" : "currentColor"} stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
)
