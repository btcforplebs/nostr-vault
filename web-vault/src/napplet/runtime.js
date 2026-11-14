// The shell runtime: from a napplet's bytes (and its manifest, when it has one) to a running, answered frame.
// Order: artifact hash -> manifest check -> domains -> grant (asked once, kept per account) -> mount through the
// loader -> dispatch. Plan P1 (RESEARCH/NV_WEB_NAPPLET_PLAN.md §6); the pieces: manifest.js, policy.js, dispatch.js,
// bus.js, host.js.
import { mountNapplet, artifactHash, LOADER_PATH } from "./host.js"
import { parseManifest, checkArtifact, domainsFor, nappletKey, SHELL_DOMAINS } from "./manifest.js"
import { defaultGrant } from "./policy.js"
import { createHandlers } from "./dispatch.js"
import { nappletOrigin } from "./origin.js"

/** A napplet with no manifest (a file the user picked): asks for every domain the shell has; the user trims it. */
export const localManifest = (name, hash, title = name, domains = SHELL_DOMAINS) => ({ kind: 0, publisher: "local", dTag: name, hash, required: ["shell"], optional: domains.filter(d => d !== "shell" && SHELL_DOMAINS.includes(d)), roles: [], intents: [], title })

/**
 * openNapplet({ html, manifestEvent?, name?, title?, firstParty?, container, grants, consent, makeDeps, loader?, onRevoke? })
 *   grants:   policy.js grantStore for the account.
 *   consent:  ({ ident, domains }) -> Promise<grant | null>: the user's answer the first time (NappletShell's sheet).
 *   makeDeps: (grantSaver) -> deps for dispatch.js (shell-deps.js shellDeps).
 *   origin:   where it runs (origin.js; tests pass their own). An outside napplet runs only on its own origin, behind
 *             the loader's guards (P2): this site without a napplet host runs our own napplets only.
 * -> { ident, grant, domains, mounted } or throws (bad manifest, wrong hash, can't run here, the user said no).
 */
export async function openNapplet({ html, manifestEvent, name = "napplet", title, firstParty = false, domains: only, container, grants, consent, makeDeps, loader = new URL(LOADER_PATH, document.baseURI).href, onRevoke, origin }) {
  const hash = await artifactHash(html)
  origin ??= nappletOrigin(hash)
  if (!origin && !firstParty) throw new Error("This site can't wall off an outside napplet yet (no napplet host), so it won't open one.")
  const manifest = manifestEvent ? parseManifest(manifestEvent) : localManifest(name, hash, title, firstParty && only ? only : undefined)
  if (manifestEvent) checkArtifact(manifest, hash)
  const asked = domainsFor(manifest)
  const ident = { publisher: firstParty ? "nostr-vault" : manifest.publisher, dTag: manifest.dTag, hash, title: manifest.title }
  const key = nappletKey(ident)
  let grant = firstParty ? defaultGrant({ firstParty: true, domains: asked }) : grants.get(key)
  if (!grant) {
    grant = await consent({ ident, domains: asked })
    if (!grant) throw new Error("not opened: the user said no")
    grant = { ...defaultGrant({ domains: grant.domains }), privateData: !!grant.privateData }
    grants.set(key, grant)
  }
  const domains = ["shell", ...asked.filter(d => d !== "shell" && grant.domains.includes(d))]
  const deps = makeDeps(g => grants.set(key, g))
  const { handlers, close } = createHandlers({ ident, grant, domains, deps })
  let mounted = null
  mounted = await mountNapplet({
    html, dTag: ident.dTag, domains, handlers, container, loader, origin: origin || undefined, needGuards: !firstParty, title: ident.title, expectHash: hash,
    onClose: () => { close(); if (mounted) deps.bus.forget(mounted.napplet) },
    onRevoke,
  })
  return { ident, grant, domains, mounted }
}
