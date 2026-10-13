// The app is served as static files at https://nostrvault.app/relay/, from website/relay/.
// `npm run build` writes there; commit the output with the source change.
export default {
  base: "/relay/",
  build: { outDir: "../website/relay", emptyOutDir: true },
}
