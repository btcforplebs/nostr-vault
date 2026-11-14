// NIP-5D napplet manifests (kinds 5129, 15129, 35129) and the domain set a mounted napplet gets. Pure: no DOM, no
// network, so node tests load it. A manifest names exactly one artifact, the sha256 of a single self-contained
// index.html (`x`), the NAP domains it needs (`R`) and may use (`O`), archetype roles (`z`) and intents (`i`).
// Plan: RESEARCH/NV_WEB_NAPPLET_PLAN.md §1; P0 findings docs/napplets/P0_SPIKE.md.
export const MANIFEST_KINDS = [5129, 15129, 35129]
const HEX64 = /^[0-9a-f]{64}$/
const DOMAIN = /^[a-z][a-z0-9-]{0,31}$/

/** The domains this shell answers (src/napplet/dispatch.js). Anything else a manifest asks for is unsupported. */
export const SHELL_DOMAINS = ["shell", "identity", "theme", "storage", "outbox", "relay", "resource", "upload", "intent", "inc", "notify", "blossom", "dm"]

const values = (tags, name) => tags.filter(t => Array.isArray(t) && t[0] === name && typeof t[1] === "string").map(t => t[1])

/**
 * A manifest event -> { kind, publisher, dTag, hash, required, optional, roles, intents, title }, or throws with the
 * reason. Does not check the signature (the caller verified the event when it read it from a relay).
 */
export function parseManifest(ev) {
  if (!ev || !MANIFEST_KINDS.includes(ev.kind)) throw new Error("not a napplet manifest (kind 5129, 15129 or 35129)")
  if (!HEX64.test(ev.pubkey ?? "")) throw new Error("manifest has no publisher")
  const tags = Array.isArray(ev.tags) ? ev.tags : []
  const x = values(tags, "x")
  if (x.length !== 1 || !HEX64.test(x[0])) throw new Error("manifest must name exactly one artifact hash (one x tag)")
  const dTag = ev.kind === 35129 ? values(tags, "d")[0] : ev.kind === 15129 ? "" : ev.id ?? ""
  if (ev.kind === 35129 && !dTag) throw new Error("addressable manifest has no d tag")
  const domains = name => [...new Set(values(tags, name).map(d => d.toLowerCase()))]
  const required = domains("R"), optional = domains("O").filter(d => !required.includes(d))
  const bad = [...required, ...optional].find(d => !DOMAIN.test(d))
  if (bad) throw new Error(`manifest names a malformed domain: ${bad.slice(0, 40)}`)
  return {
    kind: ev.kind, publisher: ev.pubkey, dTag, hash: x[0], required, optional,
    roles: values(tags, "z"), intents: values(tags, "i"), title: values(tags, "title")[0] ?? values(tags, "name")[0] ?? dTag,
  }
}

/** The napplet's artifact hash must be the manifest's, or nothing is mounted. */
export function checkArtifact(manifest, hash) {
  if (manifest.hash !== hash) throw new Error(`artifact hash ${hash.slice(0, 12)}… is not the manifest's ${manifest.hash.slice(0, 12)}…`)
}

/**
 * The domains to install and answer for a napplet: every required one (or throw: it can't run here), plus the
 * optional ones this shell has. `shell` is always in: it is how a napplet learns what it got.
 */
export function domainsFor(manifest, supported = SHELL_DOMAINS) {
  const missing = manifest.required.filter(d => !supported.includes(d))
  if (missing.length) throw new Error(`this shell can't run it: no ${missing.join(", ")}`)
  return [...new Set(["shell", ...manifest.required, ...manifest.optional.filter(d => supported.includes(d))])]
}

/** Who a napplet is, for grants and storage: NIP-5D identity is (dTag, artifact hash), under its publisher. */
export const nappletKey = ({ publisher, dTag, hash }) => `${publisher}:${dTag}:${hash}`
/** The same napplet across versions (storage's "shared" scope). A picked file has no publisher to tie versions
 *  together, and its name proves nothing (two files called napplet.html are strangers), so its line is its hash. */
export const nappletLine = ({ publisher, dTag, hash }) => (publisher === "local" ? `local:${hash}` : `${publisher}:${dTag}`)
