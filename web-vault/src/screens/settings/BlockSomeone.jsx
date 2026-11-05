// Settings › Blocked › Block Someone (iPhone BlockedSettingsView): an npub (or nprofile, or hex key) and Block, which
// opens the same confirmation as Block on a note or profile (components/Moderation.jsx BlockDialog).
import { useState } from "preact/hooks"
import { npubEncode } from "nostr-tools/nip19"
import { BlockDialog } from "../../components/Moderation.jsx"
import { getProfile } from "../../net/profiles.js"
import { SettingInfo } from "../../components/SettingInfo.jsx"
import { blockTarget } from "./block-someone.js"

export function BlockSomeone({ ctx }) {
  const [text, setText] = useState("")
  const [target, setTarget] = useState(null)
  const pk = blockTarget(text, ctx.session.pubkey)
  const name = target ? getProfile(target)?.name || npubEncode(target).slice(0, 12) + "…" : ""
  return (
    <section class="settings-group">
      <div class="section-label">Block Someone<SettingInfo topic="account.blocked" /></div>
      <form class="block-someone" onSubmit={e => { e.preventDefault(); if (pk) setTarget(pk) }}>
        <input value={text} onInput={e => setText(e.currentTarget.value)} placeholder="npub1..." aria-label="npub to block"
          autocapitalize="off" autocorrect="off" spellcheck={false} />
        <button type="submit" class="small danger-fill" disabled={!pk}>Block</button>
      </form>
      {target && <BlockDialog ctx={ctx} pubkey={target} name={name} onClose={() => { setTarget(null); setText("") }} />}
    </section>
  )
}
