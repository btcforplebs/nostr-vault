// Publishes a built site dir as an nsite (NIP-5A): uploads each file to Blossom (BUD-02), then signs and sends the
// site manifest (kind 15128) with its Blossom (10063) and relay (10002) lists. Then waits until the nsite.lol gateway
// serves the new pages. Run by ../publish-nsite.sh, which finds the site and the key.
//   node publish.mjs <site-dir>
// NSITE_KEY: the site's nsec file (default: the one *.nsec in ~/.nostrvault-site/). Whoever holds it can replace the
// whole site, so it stays out of the repo. NSITE_SERVERS / NSITE_RELAYS: comma lists to override the defaults below.
import { finalizeEvent, getPublicKey, nip19, Relay } from 'nostr-tools'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative, extname } from 'node:path'
import { homedir } from 'node:os'
import { createHash } from 'node:crypto'

const list = (env, def) => (process.env[env] || def).split(',').map(s => s.trim().replace(/\/$/, '')).filter(Boolean)
// Both took anonymous uploads up to 26 MB (RESEARCH test, 2026-10-23); blossom.band, nostr.build and nostrcheck refuse wasm.
const SERVERS = list('NSITE_SERVERS', 'https://blossom.primal.net,https://nostr.download')
// relay.damus.io is left out: it refuses this house's IP.
const RELAYS = list('NSITE_RELAYS', 'wss://nos.lol,wss://relay.primal.net,wss://purplepag.es,wss://relay.nsite.lol')
const GATEWAY = 'nsite.lol' // the public gateway that serves the whole site (nsite.run's own CSP breaks /vault/)
// Pages the gateway must serve at the new hash before the publish counts as done.
const CHECK = ['/index.html', '/docs/index.html', '/vault/index.html', '/relay/index.html']

const dir = process.argv[2]
if (!dir) { console.error('usage: node publish.mjs <site-dir>'); process.exit(1) }
const keyFile = process.env.NSITE_KEY || (() => {
  const d = join(homedir(), '.nostrvault-site'), keys = readdirSync(d).filter(n => n.endsWith('.nsec'))
  if (keys.length !== 1) { console.error(`publish: want one *.nsec in ${d}, found ${keys.length}; set NSITE_KEY`); process.exit(1) }
  return join(d, keys[0])
})()
const sk = nip19.decode(readFileSync(keyFile, 'utf8').trim()).data
const npub = nip19.npubEncode(getPublicKey(sk))

// Not site content: precompressed sidecars (Blossom stores the raw file, the gateway compresses), the docs sources,
// and build/deploy files.
const SKIP = [/\.(gz|br|sh)$/, /(^|\/)\.DS_Store$/, /^docs\/_(src|tools)\//, /^nsite\//, /^(Dockerfile|docker-compose\.yml|nginx\.conf)$/]
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.gif': 'image/gif', '.ico': 'image/x-icon', '.mp4': 'video/mp4', '.webm': 'video/webm', '.webmanifest': 'application/manifest+json', '.txt': 'text/plain', '.woff2': 'font/woff2', '.xml': 'application/xml' }
const walk = d => readdirSync(d).flatMap(n => { const p = join(d, n); return statSync(p).isDirectory() ? walk(p) : [p] })
const files = walk(dir).map(p => ({ p, rel: relative(dir, p) })).filter(f => !SKIP.some(r => r.test(f.rel)))
for (const page of CHECK) if (!files.some(f => '/' + f.rel === page)) { console.error(`publish: ${dir} has no ${page}`); process.exit(1) }

const now = () => Math.floor(Date.now() / 1000)
const auth = x => 'Nostr ' + Buffer.from(JSON.stringify(finalizeEvent({ kind: 24242, created_at: now(), content: 'Upload', tags: [['t', 'upload'], ['x', x], ['expiration', String(now() + 600)]] }, sk))).toString('base64')

// Upload what a server lacks; content addressing skips unchanged files. A file must reach every server, so a gateway
// that tries any one of them finds it.
const paths = []
let sent = 0, failed = 0
for (const f of files) {
  const buf = readFileSync(f.p), x = createHash('sha256').update(buf).digest('hex')
  paths.push(['path', '/' + f.rel, x])
  for (const s of SERVERS) {
    const head = await fetch(`${s}/${x}`, { method: 'HEAD' }).catch(() => null)
    if (head?.ok) continue
    const type = TYPES[extname(f.rel).toLowerCase()] || 'application/octet-stream'
    const r = await fetch(`${s}/upload`, { method: 'PUT', headers: { Authorization: auth(x), 'Content-Type': type, 'X-SHA-256': x }, body: buf }).catch(e => ({ ok: false, status: e.message, headers: new Headers(), text: async () => '' }))
    // 409: the server already has the blob (it answered HEAD with something else).
    if (r.ok || r.status === 409) { sent++; continue }
    failed++
    console.error(`publish: FAIL ${s} /${f.rel} ${r.status} ${(await r.text()).slice(0, 120)} ${r.headers.get('x-reason') || ''}`)
  }
}
console.log(`publish: ${files.length} files, ${sent} uploads, ${failed} failed`)
if (failed) { console.error('publish: upload failures, manifest NOT published; the nsite still serves the previous release'); process.exit(1) }

const t = now()
const manifest = finalizeEvent({ kind: 15128, created_at: t, content: '', tags: [...paths, ...SERVERS.map(s => ['server', s]), ['title', 'Nostr Vault']] }, sk)
const events = [
  manifest,
  finalizeEvent({ kind: 10063, created_at: t, content: '', tags: SERVERS.map(s => ['server', s]) }, sk),
  finalizeEvent({ kind: 10002, created_at: t, content: '', tags: RELAYS.map(r => ['r', r]) }, sk),
]
let manifestOk = 0
for (const url of RELAYS) {
  let relay
  try {
    relay = await Relay.connect(url)
    for (const e of events) {
      try { await relay.publish(e); if (e.kind === 15128) manifestOk++ } catch (err) { console.error(`publish: ${url} kind ${e.kind}: ${err.message || err}`) }
    }
  } catch (err) { console.error(`publish: ${url} connect: ${err.message || err}`) }
  relay?.close()
}
console.log(`publish: manifest ${manifest.id} on ${manifestOk}/${RELAYS.length} relays`)
if (manifestOk < 2) { console.error('publish: manifest reached fewer than 2 relays'); process.exit(1) }

// The gateway caches a site's manifest, so the new pages can take a few minutes to appear.
const base = `https://${npub}.${GATEWAY}`
const want = Object.fromEntries(paths.map(([, p, x]) => [p, x]))
const deadline = Date.now() + 10 * 60_000
let stale = CHECK
while (stale.length && Date.now() < deadline) {
  const got = await Promise.all(stale.map(async p => {
    const r = await fetch(base + p, { cache: 'no-store' }).catch(() => null)
    const body = r?.ok ? Buffer.from(await r.arrayBuffer()) : null
    return body && createHash('sha256').update(body).digest('hex') === want[p]
  }))
  stale = stale.filter((_, i) => !got[i])
  if (stale.length) await new Promise(r => setTimeout(r, 20_000))
}
if (stale.length) { console.error(`publish: after 10 min ${base} still serves old or no ${stale.join(' ')}`); process.exit(1) }
console.log(`publish: ok, ${base}/ serves this release`)
