// Runs the proof in this page, or (#...,"context":"worker") in a dedicated module worker.
import { runProof } from "./proof.js"

const params = JSON.parse(decodeURIComponent(location.hash.slice(1)))
if (params.context === "worker") {
  const w = new Worker(new URL("./worker.js", import.meta.url), { type: "module" })
  w.onmessage = e => (window.__result = e.data)
  w.onerror = e => (window.__result = { ok: false, checks: [{ name: "worker error", pass: false, detail: e.message }], data: {} })
  w.postMessage(params)
} else {
  runProof(params).then(r => (window.__result = r))
}
