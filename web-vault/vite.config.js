// Nostr Vault on the web. Haven (haven.wasm) and the FIPS relay code are imported from ../web-relay, not copied:
// build web-relay's wasm first (../web-relay/tools/build-haven-wasm.sh) and `npm ci` there for the @fips packages.
import { precompress } from "../web-relay/vite.config.js"

export default {
  base: "/vault/",
  build: { outDir: "dist", emptyOutDir: true, target: "es2022" },
  esbuild: { jsx: "automatic", jsxImportSource: "preact" },
  resolve: { dedupe: ["nostr-tools", "preact"] },
  server: { fs: { allow: [".."] } },
  plugins: [precompress(), preloadHaven()],
}

// haven.wasm (~6 MB gzipped) is what a first visit waits on, and the app's script only asks for it once it has
// loaded and run. A preload in index.html starts it alongside that script. Same URL and mode (cors, same-origin
// credentials) as loadHaven's fetch, so the browser hands that fetch the preloaded response.
function preloadHaven() {
  let base
  return {
    name: "preload-haven",
    apply: "build",
    configResolved: c => { base = c.base },
    transformIndexHtml: {
      order: "post",
      handler(html, { bundle }) {
        const file = Object.keys(bundle ?? {}).find(f => /(^|\/)haven-[\w-]+\.wasm$/.test(f))
        if (!file) throw new Error("preload-haven: no haven-*.wasm in the build")
        return [{ tag: "link", attrs: { rel: "preload", href: base + file, as: "fetch", type: "application/wasm", crossorigin: true }, injectTo: "head" }]
      },
    },
  }
}
