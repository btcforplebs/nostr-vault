// NAP-BLOSSOM for napplets (plan P5, napplet/naps PR 71): the Media napplet lists, copies and deletes the user's files
// on the user's media servers. Every Blossom authorisation (kind 24242) is signed by the shell's own gallery code
// (net/blossom-gallery.js, through deps) and never handed to a napplet (policy.js NEVER_SIGN). Pure apart from `deps`, so node tests drive it with fakes.
//   blossom.servers                         -> the user's media servers (kind 10063, else the defaults)
//   blossom.list { server, pubkey }         -> that server's list; only the user's own servers and own pubkey
//   blossom.mirror { server, url, sha256 }  -> asks that server to copy the file (BUD-04)
//   blossom.delete { server, sha256 }       -> deletes it from that server (BUD-02); the user is asked first, every
//                                              napplet ours too, once per file for a minute (Delete from mirrors
//                                              sends one delete per server). A server that is one of the user's own
//                                              vaults keeps its copy (blossom-gallery.js deleteBlob).
// Outside napplets need the private-data grant to see the list (it can be auth-gated) and are asked before a mirror.
// Anything else (get, upload, server list edits) is "unsupported": bytes come through resource, uploads through upload.
import { seesPrivate } from "./policy.js"

const HEX64 = /^[0-9a-f]{64}$/
export const DELETE_YES_MS = 60_000
const origin = s => { try { const u = new URL(s); return u.protocol === "https:" || u.protocol === "http:" ? `${u.origin}${u.pathname.replace(/\/+$/, "")}` : null } catch { return null } }
const fail = (status, error) => ({ ok: false, status, error })

/**
 * deps: { pubkey, servers(): Promise<[server]>, list(server, pubkey) -> { blobs, status }, mirror(blob, server) ->
 * [{ ok, message }], remove(blob, server) -> [{ ok, kept?, message }], ask({ napplet, what, detail }) -> bool, now(),
 * describe?(url) -> { size, type } | null (what the delete sheet shows besides the picture) }
 */
export function blossomHandler({ grant, who, deps }) {
  let said = new Map() // sha256 -> when the user said yes to deleting it
  const own = async server => {
    const s = origin(server)
    const mine = (await deps.servers().catch(() => [])).map(origin)
    return s && mine.includes(s) ? s : null
  }
  const reply = (m, result) => ({ type: `${m.type}.result`, id: m.id, result })
  const refuse = (m, error) => ({ type: `${m.type}.result`, id: m.id, error })

  return async m => {
    if (typeof m?.type !== "string" || typeof m.id !== "string") return undefined
    const r = m.request ?? {}
    switch (m.type) {
      case "blossom.servers":
        if (!seesPrivate(grant)) return refuse(m, "private: no private-data grant")
        return reply(m, { ok: true, servers: await deps.servers().catch(() => []) })
      case "blossom.list": {
        if (!seesPrivate(grant)) return refuse(m, "private: no private-data grant")
        if (r.pubkey !== deps.pubkey) return refuse(m, "only your own files are listed")
        const server = await own(r.server)
        if (!server) return refuse(m, "not one of your media servers")
        const got = await deps.list(server, deps.pubkey)
        const st = got.status?.[server]
        if (st && st !== "ok") return reply(m, { ...fail(502, st), blobs: [] })
        return reply(m, { ok: true, status: 200, blobs: (got.blobs ?? []).map(b => ({ url: b.url, sha256: b.sha256, size: b.size, type: b.type, uploaded: b.uploaded })) })
      }
      case "blossom.mirror": {
        const server = await own(r.server)
        if (!server) return refuse(m, "not one of your media servers")
        if (!HEX64.test(r.sha256 ?? "") || !/^https:\/\//i.test(r.url ?? "")) return refuse(m, "a mirror needs the file's sha256 and its https url")
        if (!grant.firstParty && !(await deps.ask({ napplet: who, what: "blossom-mirror", detail: { sha256: r.sha256, server } }))) return reply(m, fail(403, "the user said no"))
        const [res] = await deps.mirror({ sha256: r.sha256, url: r.url, servers: [] }, server)
        return reply(m, res?.ok ? { ok: true, status: 200, descriptor: { url: r.url, sha256: r.sha256, size: 0, type: "", uploaded: 0 } } : fail(502, res?.message || "the server didn't copy it"))
      }
      case "blossom.delete": {
        const server = await own(r.server)
        if (!server) return refuse(m, "not one of your media servers")
        if (!HEX64.test(r.sha256 ?? "")) return refuse(m, "a delete needs the file's sha256")
        const t = said.get(r.sha256)
        if (!(t && deps.now() - t < DELETE_YES_MS)) {
          // Hashes are public (any note names them), so the sheet shows which file this is: its picture, size and type.
          const url = `${server}/${r.sha256}`
          const seen = await deps.describe?.(url).catch(() => null)
          if (!(await deps.ask({ napplet: who, what: "blossom-delete", detail: { sha256: r.sha256, server, url, size: seen?.size, type: seen?.type } }))) return reply(m, fail(403, "the user said no"))
          said.set(r.sha256, deps.now())
          if (said.size > 200) said = new Map([[r.sha256, deps.now()]])
        }
        const results = await deps.remove({ sha256: r.sha256, url: `${server}/${r.sha256}`, servers: [server] }, server)
        const res = results.find(x => origin(x.server) === server) ?? results[0]
        if (res?.kept) return reply(m, fail(409, "your own vault: kept"))
        return reply(m, res?.ok ? { ok: true, status: 200 } : fail(502, res?.message || "not deleted"))
      }
      default:
        return refuse(m, "unsupported")
    }
  }
}
