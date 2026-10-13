// Nostr Vault on the web. Haven (haven.wasm) and the FIPS relay code are imported from ../web-relay, not copied:
// build web-relay's wasm first (../web-relay/tools/build-haven-wasm.sh) and `npm ci` there for the @fips packages.
export default {
  base: "/vault/",
  build: { outDir: "dist", emptyOutDir: true, target: "es2022" },
  esbuild: { jsx: "automatic", jsxImportSource: "preact" },
  resolve: { dedupe: ["nostr-tools", "preact"] },
  server: { fs: { allow: [".."] } },
}
