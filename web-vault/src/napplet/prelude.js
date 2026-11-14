// The maintained NIP-5D runtime prelude (@napplet/shim's prelude.global, pinned to an exact version in package.json)
// and the call that installs only the domains a napplet is given. Inlined into every napplet's srcdoc.
import source from "@napplet/shim/prelude.global?raw"

export const preludeFor = (domains) =>
  `${source}\nglobalThis.NappletShimPrelude.install(${JSON.stringify({ domains: [...domains] })});`
