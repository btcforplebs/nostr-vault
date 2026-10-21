import { runProof } from "./proof.js"

self.onmessage = async e => self.postMessage(await runProof(e.data))
