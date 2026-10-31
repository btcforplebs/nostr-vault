// Nostr Vault on the web. Haven (haven.wasm) and the FIPS relay code are imported from ../web-relay, not copied:
// build web-relay's wasm first (../web-relay/tools/build-haven-wasm.sh) and `npm ci` there for the @fips packages.
import { execSync } from "node:child_process"
import { precompress } from "../web-relay/vite.config.js"

// The commit About shows: NV_COMMIT from the site build (website/Dockerfile, set by deploy.sh; the image has no .git),
// else this checkout's own, else none.
const commit = process.env.NV_COMMIT || (() => {
  try { return execSync("git rev-parse --short=12 HEAD", { stdio: ["ignore", "pipe", "ignore"] }).toString().trim() } catch { return "" }
})()

// NV_BOX=1: the build NV for Linux serves at its own root, its vault the box on the same origin (src/box/mode.js).
const box = process.env.NV_BOX === "1"

export default {
  base: box ? "/" : "/vault/",
  build: { outDir: "dist", emptyOutDir: true, target: "es2022" },
  esbuild: { jsx: "automatic", jsxImportSource: "preact" },
  resolve: { dedupe: ["nostr-tools", "preact"] },
  define: { __NV_COMMIT__: JSON.stringify(commit), __NV_BOX__: JSON.stringify(box) },
  server: { fs: { allow: [".."] } },
  plugins: [precompress()], // haven.wasm's preload: main.jsx, for someone signed in (src/haven/vault.js preloadHaven)
}
