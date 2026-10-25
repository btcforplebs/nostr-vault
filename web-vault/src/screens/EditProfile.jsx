// Edit Profile (iPhone ProfileEditView, the Mac's Cancel / Save form): banner and preview over the Identity, Bio,
// Media and Lightning fields; a picture or banner can be uploaded to the account's media servers, and its link
// lands in the field below, the same as pasting one. Save publishes a new kind 0 (net/profile-edit.js).
import { useEffect, useRef, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { formFields, hasChanges, latestProfile, localProfile, saveProfile } from "../net/profile-edit.js"
import { mediaServers, uploadPhoto } from "../net/upload.js"
import "../styles/profile-edit.css"

const GROUPS = [
  ["IDENTITY", [["display_name", "Display Name", "Satoshi Nakamoto"], ["name", "Username", "satoshi"], ["nip05", "NIP-05", "you@domain.com", "email"]]],
  ["BIO", [["about", "About", "Tell people about yourself…", "multi"]]],
  ["MEDIA", [["picture", "Picture URL", "https://…", "url"], ["banner", "Banner URL", "https://…", "url"], ["website", "Website", "yourdomain.com", "url"]]],
  ["LIGHTNING", [["lud16", "Address (lud16)", "you@walletofsatoshi.com", "email"]]],
]

// photo.badge.plus: a picture with a plus at its corner.
const PHOTO_ADD = "M14 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5M3 16l4-4 3 3 3-3 3 3M8.5 9.5h.01M19 2v6M16 5h6"
const isUrl = s => { try { return !!new URL(s.trim()).protocol } catch { return false } }

export function EditProfile({ ctx, onClose }) {
  const me = ctx.session.pubkey
  const [initial, setInitial] = useState(null)
  const [form, setForm] = useState(null)
  const [saving, setSaving] = useState(false)
  const [uploading, setUploading] = useState("") // "picture" | "banner" while one uploads
  const [err, setErr] = useState("")
  const [uploadErr, setUploadErr] = useState("")

  const touched = useRef(false)

  // Opens with this browser's copy at once; a newer one from the relays replaces it while nothing has been typed.
  useEffect(() => {
    let live = true
    const show = ev => { const f = formFields(ev); setInitial(f); setForm(f) }
    localProfile(ctx.vault, me).catch(() => undefined).then(async local => {
      if (!live) return
      show(local)
      const { event } = await latestProfile(ctx).catch(() => ({}))
      if (live && event && event.created_at > (local?.created_at ?? 0) && !touched.current) show(event)
    })
    return () => { live = false }
  }, [])

  const set = (k, v) => { touched.current = true; setForm(f => ({ ...f, [k]: v })) }
  const changed = !!form && hasChanges(initial, form)
  const busy = saving || !!uploading

  const save = async () => {
    setErr(""); setSaving(true)
    try { await saveProfile(ctx, initial, form); onClose() } catch (e) { setErr(String(e?.message ?? e)); setSaving(false) }
  }
  const upload = async (key, file) => {
    if (!file) return
    setUploading(key); setUploadErr("")
    try { set(key, (await uploadPhoto(file, { ctx, servers: await mediaServers(ctx) })).url) } catch (e) { setUploadErr(String(e?.message ?? e)) } finally { setUploading("") }
  }

  if (!form) return <main class="screen"><p class="empty">Loading…</p></main>
  const shown = form.display_name.trim() || form.name.trim() || "Unnamed"
  return (
    <main class="screen edit-profile">
      <header class="screen-head">
        <button type="button" class="small" disabled={busy} onClick={onClose}>Cancel</button>
        <h2>Edit Profile</h2>
        <button type="button" class="small save" disabled={busy || !changed} onClick={save} aria-busy={saving || undefined}>{saving ? "Saving…" : "Save"}</button>
      </header>
      {isUrl(form.banner) && <div class="edit-banner" aria-label="Banner preview"><img src={form.banner.trim()} alt="" /></div>}
      <div class="edit-preview">
        {isUrl(form.picture) ? <img class="avatar" style={{ width: 56, height: 56 }} src={form.picture.trim()} alt="" /> : <Avatar pubkey={me} size={56} />}
        <div>
          <b>{shown}</b>
          {form.nip05.trim() && <div class="muted small">{form.nip05}</div>}
          {form.about.trim() && <p class="small">{form.about}</p>}
        </div>
      </div>
      {GROUPS.map(([title, fields]) => (
        <section class="edit-group" key={title}>
          <h3>{title}</h3>
          {title === "MEDIA" && (
            <div class="edit-uploads">
              {["picture", "banner"].map(k => (
                <label key={k} class={`button small${busy ? " disabled" : ""}`}>
                  <input type="file" accept="image/*" hidden disabled={busy} onChange={e => { upload(k, e.currentTarget.files?.[0]); e.currentTarget.value = "" }} />
                  <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={PHOTO_ADD} /></svg>
                  {uploading === k ? "Uploading…" : `Choose ${k}`}
                </label>
              ))}
              {uploadErr && <p class="small error">{uploadErr}</p>}
            </div>
          )}
          {fields.map(([k, label, placeholder, kind]) => (
            <label class="edit-field" key={k}>
              <span>{label}</span>
              {kind === "multi"
                ? <textarea rows={4} placeholder={placeholder} value={form[k]} disabled={saving} onInput={e => set(k, e.currentTarget.value)} />
                : <input type={kind === "url" ? "url" : "text"} inputmode={kind === "email" ? "email" : kind === "url" ? "url" : undefined}
                    autocapitalize={kind ? "off" : undefined} autocorrect={kind ? "off" : undefined} spellcheck={kind ? false : undefined}
                    placeholder={placeholder} value={form[k]} disabled={saving} onInput={e => set(k, e.currentTarget.value)} />}
            </label>
          ))}
        </section>
      ))}
      {err && <p class="error edit-error" role="alert">{err}</p>}
    </main>
  )
}

