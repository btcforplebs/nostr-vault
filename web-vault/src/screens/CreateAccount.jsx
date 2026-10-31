// Create an account: the iPhone's New to Nostr path (Views/SetupWizard, steps 9, 10, 11 and the done step), plus a
// follows step so the feed isn't empty on the first open. What Nostr is -> Create My Account makes a key in this
// browser -> both keys, and the secret key saved ("I saved my secret key") -> a password that locks it (NIP-49) ->
// name and photo (skippable) -> people to follow -> Start Exploring.
// The secret key stays in this component's memory until the last step, where it is locked (signer/local.js) and the
// account's first events are signed and sent (net/new-account.js). Nothing is stored or sent before that, and the key
// is never logged.
import { useEffect, useMemo, useRef, useState } from "preact/hooks"
import { newKey, checkPassword, localSession, localSigner, MIN_PASSWORD, CREATING } from "../signer/local.js"
import { assertCanSeal } from "../signer/keyring.js"
import { starterPacks, newAccountTemplates, signAll, publishNewAccount, NEW_ACCOUNT_RELAYS } from "../net/new-account.js"
import { StarterRelays } from "../components/StarterRelays.jsx"
import { uploadPhoto, DEFAULT_MEDIA_SERVERS } from "../net/upload.js"
import { withTimeout } from "../signer/readonly.js"
import { askToKeep, sevenDayErase, KEEP_IT } from "../components/StorageNote.jsx"
import { KeyCard, painted } from "../components/KeyCard.jsx"
import "../styles/onboarding.css"

const STEPS = ["intro", "keys", "password", "profile", "follows", "relays", "done"]
const PUBLISH_WAIT_MS = 12000

/** `onSignedIn({ signer, session, firstEvents })`: main.jsx's. `onBack`: to the welcome screen. */
export function CreateAccount({ onSignedIn, onBack }) {
  const [step, setStep] = useState(0)
  const [key, setKey] = useState(null) // { sk, pubkey, npub, nsec }
  const [password, setPassword] = useState("")
  const [name, setName] = useState("")
  const [photo, setPhoto] = useState(null) // { blob, url } a 512px JPEG, drawn here (its metadata left behind)
  const packs = useMemo(() => starterPacks(), [])
  const [relays, setRelays] = useState(NEW_ACCOUNT_RELAYS)
  const [picked, setPicked] = useState(() => new Set(packs.filter(p => p.on).flatMap(p => p.accounts.map(a => a.pubkey))))
  const top = useRef()
  // Each step starts at its heading, for a screen reader and for a long step on a small phone.
  useEffect(() => { top.current?.focus(); scrollTo(0, 0) }, [step])
  // Leaving without finishing: the key in memory is wiped.
  useEffect(() => () => key?.sk.fill(0), [key])

  const next = () => setStep(s => s + 1)
  const back = () => (step === 0 ? onBack() : setStep(s => s - 1))
  const id = STEPS[step]

  return (
    <main class="onboard">
      <header class="onboard-head">
        {id !== "done" && <button type="button" class="small" onClick={back}>‹ Back</button>}
        {step > 0 && <ol class="onboard-dots" aria-label={`Step ${step} of ${STEPS.length - 1}`}>
          {STEPS.slice(1).map((s, i) => <li key={s} class={i + 1 === step ? "on" : i + 1 < step ? "done" : ""} />)}
        </ol>}
      </header>
      <div class="onboard-body" ref={top} tabIndex={-1}>
        {id === "intro" && <Intro onCreate={() => { setKey(k => k ?? newKey()); next() }} />}
        {id === "keys" && key && <Keys keyPair={key} onContinue={next} />}
        {id === "password" && <Password initial={password} onContinue={p => { setPassword(p); next() }} />}
        {id === "profile" && <Profile name={name} setName={setName} photo={photo} setPhoto={setPhoto} onContinue={next}
          onSkip={() => { setName(""); setPhoto(null); next() }} />}
        {id === "follows" && <Follows packs={packs} picked={picked} setPicked={setPicked} onContinue={next} />}
        {id === "relays" && <StarterRelays relays={relays} setRelays={setRelays} onContinue={next} />}
        {id === "done" && <Done keyPair={key} password={password} name={name} photo={photo} follows={[...picked]} relays={relays} onSignedIn={onSignedIn} onBack={() => setStep(s => s - 1)} />}
      </div>
    </main>
  )
}

/** Step 9's first page: what Nostr is, what the vault adds, and Create My Account. */
function Intro({ onCreate }) {
  const [err, setErr] = useState("")
  const create = () => {
    // A page that can't lock the key (plain http) says so now, not after the user wrote it down.
    try { assertCanSeal(CREATING) } catch (e) { setErr(String(e?.message ?? e)); return }
    onCreate()
  }
  return (
    <>
      <img src="./icon.svg" alt="" class="onboard-logo" width="56" height="56" />
      <section class="onboard-card">
        <h2>Welcome to Nostr</h2>
        <p>Nostr is an open social network. You own your account through a pair of keys, so no company controls it. Your posts go out to relays, and anyone can read them.</p>
      </section>
      <section class="onboard-card">
        <h2>Your personal archive</h2>
        <p>Nostr Vault runs a relay right here in your browser. The notes, messages and photos you see are kept on your device, not on someone else's server.</p>
      </section>
      {err && <p class="error small" role="alert">{err}</p>}
      <button type="button" class="primary onboard-main" onClick={create}>Create My Account</button>
    </>
  )
}

/** Step 9's second page: both keys, and the secret one saved before Continue. */
function Keys({ keyPair, onContinue }) {
  const [saved, setSaved] = useState(false)
  return (
    <>
      <h1 class="onboard-title">Your Keys</h1>
      <p class="onboard-sub">Two keys replace a username and password.</p>
      <KeyCard title="Public key" caption="Your name on Nostr. Share it freely." value={keyPair.npub} />
      <KeyCard title="Secret key" secret caption="Your password to Nostr. Anyone who has it can post as you, so never share it." value={keyPair.nsec} />
      <label class="onboard-tick">
        <input type="checkbox" checked={saved} onChange={e => setSaved(e.currentTarget.checked)} />
        <span>I saved my secret key</span>
      </label>
      <button type="button" class="primary onboard-main" disabled={!saved} onClick={onContinue}>Continue</button>
    </>
  )
}

/** Step 10: the password that locks the key (NIP-49), at least 8 characters, typed twice. */
function Password({ initial, onContinue }) {
  const [pw, setPw] = useState(initial)
  const [confirm, setConfirm] = useState(initial)
  const [show, setShow] = useState(false)
  const { ok, problem } = checkPassword(pw, confirm)
  const submit = e => { e.preventDefault(); if (ok) onContinue(pw) }
  return (
    <form onSubmit={submit} class="onboard-form">
      <h1 class="onboard-title">Protect Your Key</h1>
      <p class="onboard-sub">This password locks the secret key you just saved. It stays in this browser only and is never sent to us or any server. We cannot recover or reset it. If you forget it, the secret key you saved is your only way back in.</p>
      {/* A hidden username, so a password manager files the password under this account. */}
      <input type="text" name="username" autocomplete="username" value="Nostr Vault key" hidden readOnly />
      <label class="field">
        <span>Password (minimum {MIN_PASSWORD} characters)</span>
        <span class="onboard-pw">
          <input type={show ? "text" : "password"} value={pw} onInput={e => setPw(e.currentTarget.value)} autocomplete="new-password"
            autocapitalize="off" autocorrect="off" spellcheck={false} minLength={MIN_PASSWORD} required />
          <button type="button" class="small" onClick={() => setShow(!show)} aria-pressed={show}>{show ? "Hide" : "Show"}</button>
        </span>
      </label>
      <label class="field">
        <span>Confirm password</span>
        <input type={show ? "text" : "password"} value={confirm} onInput={e => setConfirm(e.currentTarget.value)} autocomplete="new-password"
          autocapitalize="off" autocorrect="off" spellcheck={false} required />
      </label>
      <p class="error small" aria-live="polite">{problem}</p>
      <button type="submit" class="primary onboard-main" disabled={!ok}>Continue</button>
      <p class="onboard-warn box">Write this password down and keep it with your secret key.</p>
    </form>
  )
}

/** Step 11: name and photo, both optional. Nothing is uploaded until the last step. */
function Profile({ name, setName, photo, setPhoto, onContinue, onSkip }) {
  const [err, setErr] = useState("")
  const pick = async e => {
    const file = e.currentTarget.files?.[0]
    e.currentTarget.value = ""
    if (!file) return
    try {
      const blob = await profileJPEG(file)
      if (photo?.url) URL.revokeObjectURL(photo.url)
      setPhoto({ blob, url: URL.createObjectURL(blob) }); setErr("")
    } catch { setErr("Couldn't read that photo. Try another.") }
  }
  return (
    <>
      <h1 class="onboard-title">Your Profile</h1>
      <p class="onboard-sub">This is how people will see you. You can change it later.</p>
      <label class="onboard-photo">
        <input type="file" accept="image/*" class="sr-only" onChange={pick} />
        <span class="onboard-photo-disc">{photo ? <img src={photo.url} alt="" /> : <CameraIcon />}</span>
        <span>{photo ? "Change Photo" : "Add Photo"}</span>
      </label>
      {err && <p class="error small" role="alert">{err}</p>}
      <label class="field">
        <span>Name</span>
        <input value={name} onInput={e => setName(e.currentTarget.value)} placeholder="Your name" autocomplete="nickname" maxLength={60} />
      </label>
      <button type="button" class="primary onboard-main" onClick={onContinue}>Continue</button>
      <button type="button" class="onboard-skip" onClick={onSkip}>Skip for Now</button>
    </>
  )
}

const CameraIcon = () => <svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8h3l2-3h6l2 3h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1z" /><circle cx="12" cy="13.5" r="3.5" /></svg>

/** A JPEG no larger than 512px on its longest side (NewProfileStep.profileJPEG). Drawing it on a canvas leaves the
 *  original's metadata, location included, behind. */
export async function profileJPEG(file, maxPixel = 512) {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxPixel / Math.max(bitmap.width, bitmap.height))
  const canvas = document.createElement("canvas")
  canvas.width = Math.max(1, Math.round(bitmap.width * scale))
  canvas.height = Math.max(1, Math.round(bitmap.height * scale))
  canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close?.()
  const blob = await new Promise(r => canvas.toBlob(r, "image/jpeg", 0.85))
  if (!blob) throw new Error("no image")
  return blob
}

/** People to follow, from the iPhone's starter packs, so the first feed has posts. Each pack picks or drops all of
 *  its people; each person can be dropped on their own. */
function Follows({ packs, picked, setPicked, onContinue }) {
  const toggle = pks => setPicked(old => {
    const s = new Set(old)
    const all = pks.every(pk => s.has(pk))
    pks.forEach(pk => (all ? s.delete(pk) : s.add(pk)))
    return s
  })
  return (
    <>
      <h1 class="onboard-title">Fill Your Feed</h1>
      <p class="onboard-sub">Pick a few people to start with. Your web of trust grows from the people you follow, so your feeds show who they vouch for.</p>
      {packs.map(p => {
        const pks = p.accounts.map(a => a.pubkey)
        const all = pks.every(pk => picked.has(pk))
        return (
          <section key={p.id} class="onboard-pack">
            <label class="onboard-pack-head">
              <span><strong>{p.name}</strong><span class="muted small">{p.description}</span></span>
              <input type="checkbox" checked={all} onChange={() => toggle(pks)} aria-label={`Follow everyone in ${p.name}`} />
            </label>
            <ul>
              {p.accounts.map(a => (
                <li key={a.pubkey}>
                  <label class="onboard-person">
                    {a.picture ? <img class="avatar" src={a.picture} alt="" width="36" height="36" loading="lazy" referrerpolicy="no-referrer" onError={e => { e.currentTarget.style.visibility = "hidden" }} />
                      : <span class="avatar avatar-blank" />}
                    <span class="onboard-person-names"><span class="author-name">{a.name}</span><span class="muted small">{a.about}</span></span>
                    <input type="checkbox" checked={picked.has(a.pubkey)} onChange={() => toggle([a.pubkey])} aria-label={`Follow ${a.name}`} />
                  </label>
                </li>
              ))}
            </ul>
          </section>
        )
      })}
      <button type="button" class="primary onboard-main sticky" onClick={onContinue}>
        {picked.size ? `Continue with ${picked.size} ${picked.size === 1 ? "person" : "people"}` : "Continue without follows"}
      </button>
    </>
  )
}

/** The done step: "Welcome to Nostr!", and Start Exploring locks the key, signs the first events and sends them. */
function Done({ keyPair, password, name, photo, follows, relays, onSignedIn, onBack, safari = sevenDayErase() }) {
  const [busy, setBusy] = useState("")
  const [err, setErr] = useState("")
  const asked = useRef(false)
  const start = async () => {
    setErr("")
    // Asked now, while the click still counts as one (Firefox shows its prompt only then), not after the publish wait.
    if (!asked.current) { asked.current = true; askToKeep() }
    try {
      setBusy("Locking your key…")
      await painted() // the lock is scrypt, which holds the page for a moment: show the label first
      const session = await localSession(keyPair.sk, password)
      const signer = localSigner(session)
      let picture = null
      if (photo) {
        setBusy("Uploading your photo…")
        // Not published as a link only this browser could serve: a photo no server took is left off (as the iPhone).
        try { picture = (await uploadPhoto(new File([photo.blob], "profile.jpg", { type: "image/jpeg" }), { ctx: { signer, session }, servers: DEFAULT_MEDIA_SERVERS })).url }
        catch {}
      }
      setBusy("Publishing your profile…")
      const events = await signAll(signer, session.pubkey, newAccountTemplates({ name, picture, follows, relays }))
      // Done at the first relay that took each event; the rest carry on in the background.
      await withTimeout(publishNewAccount(events, { relays }), PUBLISH_WAIT_MS, "slow").catch(() => {})
      keyPair.sk.fill(0)
      location.hash = "#/feed"
      onSignedIn({ signer, session, firstEvents: events })
    } catch (e) {
      setErr(String(e?.message ?? e)); setBusy("")
    }
  }
  return (
    <>
      <img src="./icon.svg" alt="" class="onboard-logo" width="56" height="56" />
      <h1 class="onboard-title">Welcome to Nostr!</h1>
      <p class="onboard-sub">Your account is ready. Here's what happens when you start:</p>
      <ul class="onboard-summary">
        <li>Your secret key is locked with your password and kept in this browser. Settings › Your Secret Key shows it again.</li>
        {(name.trim() || photo) && <li>Your profile{name.trim() ? `, ${name.trim()},` : ""} goes out to your {relays.length} {relays.length === 1 ? "server" : "servers"}.</li>}
        <li>{follows.length ? `You follow ${follows.length} ${follows.length === 1 ? "person" : "people"}, so your feed has posts right away.` : "You follow nobody yet: find people in Search or on the Global feed."}</li>
      </ul>
      {/* Safari's 7-day rule takes the key with the rest of the site's data: said here, before it can happen. */}
      {KEEP_IT[safari] && <p class="onboard-warn box">{KEEP_IT[safari]} Without it, the secret key you saved is the only way back: add it to a Nostr browser extension and choose "I already use Nostr", or import it in the Nostr Vault app.</p>}
      {err && <p class="error small" role="alert">{err}</p>}
      <button type="button" class="primary onboard-main" disabled={!!busy} aria-busy={!!busy || undefined} onClick={start}>{busy || "Start Exploring"}</button>
      {!busy && <button type="button" class="onboard-skip" onClick={onBack}>‹ Back</button>}
    </>
  )
}
