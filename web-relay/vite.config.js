// The app is served as static files at https://nostrvault.app/relay/, from website/relay/.
// `npm run build` writes there at deploy time; the output is not committed (.gitignore).
import fs from "node:fs"; import path from "node:path"; import zlib from "node:zlib"

/** Writes a .br and a .gz next to every compressible build output, for servers that serve precompressed files
 *  (server.mjs here and in web-vault). haven.wasm is ~27 MB raw, ~4.7 MB as brotli. Quality 11 takes ~40 s on it. */
export function precompress({ min = 1024 } = {}) {
  let outDir
  return {
    name: "precompress",
    apply: "build",
    configResolved: c => { outDir = path.resolve(c.root, c.build.outDir) },
    closeBundle() {
      if (!fs.existsSync(outDir)) return // the build failed; let its own error show
      const files = fs.readdirSync(outDir, { recursive: true }).map(f => path.join(outDir, f))
      for (const f of files) {
        if (!/\.(wasm|js|mjs|css|html|svg|json|webmanifest)$/.test(f) || fs.statSync(f).size < min) continue
        const b = fs.readFileSync(f)
        fs.writeFileSync(`${f}.br`, zlib.brotliCompressSync(b, { params: {
          [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_LGWIN]: 24, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: b.length } }))
        fs.writeFileSync(`${f}.gz`, zlib.gzipSync(b, { level: 9 }))
      }
    },
  }
}

export default {
  base: "/relay/",
  build: { outDir: "../website/relay", emptyOutDir: true },
  plugins: [precompress()],
}
