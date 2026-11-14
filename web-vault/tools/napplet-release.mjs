#!/usr/bin/env node
// Ready-to-publish files for our napplets (plan P8, Logen's decision 3: publish only after the whole build, and only
// on his say). For each napplet in src/napplet/first-party-list.js (samples left out) this writes:
//   <out>/<d>/index.html             the exact bytes the app runs (the WoT maths injected as in the app)
//   <out>/<d>/manifest.unsigned.json a kind 35129 template: d, x (the sha256 of index.html), title, summary, R per NAP
//                                    domain, i per intent. Unsigned, never sent.
//   <out>/RELEASE.md                 hashes, sizes and the steps that are still to do.
// It signs nothing, uploads nothing and opens no socket. Usage: node tools/napplet-release.mjs [out-dir]
import fs from "node:fs"
import path from "node:path"
import crypto from "node:crypto"
import { fileURLToPath } from "node:url"
import { FIRST_PARTY_LIST } from "../src/napplet/first-party-list.js"
import { injectWot } from "../src/napplet/wot-inject.js"
import { parseManifest } from "../src/napplet/manifest.js"

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..")
const read = p => fs.readFileSync(path.join(root, p), "utf8")

/** One napplet's artifact bytes, as the app builds them (first-party.js). */
export function artifactOf(n, readFile = read) {
  const html = readFile(`napplets/${n.file}/index.html`)
  return n.maths ? injectWot(html, [readFile("src/net/wot-pure.js"), readFile("src/net/wot-globe.js")]) : html
}

/** The unsigned kind 35129 for an artifact. `created_at` is left for whoever signs it. */
export function manifestTemplate(n, html) {
  const x = crypto.createHash("sha256").update(html, "utf8").digest("hex")
  return {
    kind: 35129, content: n.summary ?? "",
    tags: [["d", n.dTag], ["x", x], ["title", n.title], ["summary", n.summary ?? ""], ...n.domains.map(d => ["R", d]), ...(n.intents ?? []).map(i => ["i", `napplet:${i}`])],
  }
}

export function release(out, { list = FIRST_PARTY_LIST, readFile = read } = {}) {
  fs.mkdirSync(out, { recursive: true })
  const rows = []
  for (const n of list.filter(x => !x.sample)) {
    const html = artifactOf(n, readFile), t = manifestTemplate(n, html)
    // The template must be one our own Apps pane accepts (parseManifest), with a stand-in publisher.
    parseManifest({ ...t, pubkey: "0".repeat(64) })
    const dir = path.join(out, n.dTag)
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, "index.html"), html)
    fs.writeFileSync(path.join(dir, "manifest.unsigned.json"), JSON.stringify(t, null, 2) + "\n")
    rows.push({ d: n.dTag, title: n.title, x: t.tags[1][1], bytes: Buffer.byteLength(html) })
  }
  fs.writeFileSync(path.join(out, "RELEASE.md"), [
    "# Nostr Vault napplets: ready, not published",
    "",
    "Built by tools/napplet-release.mjs. Nothing here is signed, uploaded or sent (Logen's decision 3).",
    "",
    "| d | title | sha256 (x) | bytes |", "|---|---|---|---|",
    ...rows.map(r => `| ${r.d} | ${r.title} | ${r.x} | ${r.bytes} |`),
    "",
    "Still to do, only on Logen's say:",
    "1. Upload each index.html to the publishing account's Blossom servers (its hash must stay the x tag).",
    "2. Sign each manifest.unsigned.json with that account (add created_at) and publish the kind 35129 to its relays.",
    "3. Our shell trusts these as first-party by built-in hash, not by the signature: the published copies are for other shells.",
    "",
  ].join("\n"))
  return rows
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const out = path.resolve(process.argv[2] ?? path.join(root, "dist-napplets"))
  for (const r of release(out)) console.log(`${r.d.padEnd(14)} ${r.x}  ${r.bytes} B`)
  console.log(`\nWritten to ${out}. Unsigned, unsent.`)
}
