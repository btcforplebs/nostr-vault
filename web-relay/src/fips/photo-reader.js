// Photo-only FIPS on the page: for a reader with no paired owner and no Haven (a stranger opening a #blob= link).
// A fresh key per start, never saved; the public seeds only (no WebRTC, so no direct link and no offers); no relay
// server; reads photos by hash from the photo addresses (vaults' blob nodes) and nothing else. Owners are never
// asked, so a stranger's link can't reach a vault's main npub through this page.
import { FipsNode, generateIdentity, encodeNpub } from "@fips/core"
import { WebSocketTransport } from "@fips/transport-websocket"
import { isOwner } from "./owners.js"
import { MeshBlobClient } from "./blob-get.js"
import { PUBLIC_SEEDS } from "./node.js"

/** A FIPS identity that lives only as long as this reader: nothing links two visits. */
export function throwawayIdentity() {
  return generateIdentity()
}

function seedNode(identity, seeds) {
  return new FipsNode({ identity, transports: [new WebSocketTransport({ seedUrls: seeds })], forwarding: false })
}

/**
 * @param getPhotoVaults () => Set<x-only hex>: the only vaults this reader may ask
 * @param onStatus       (status) => void, called on every change
 * @param makeNode       (identity) => FipsNode-shaped: on, start, stop, sendDatagram (tests pass a fabric)
 */
export async function startPhotoReader({ getPhotoVaults, onStatus = () => {}, seeds = PUBLIC_SEEDS, identity, makeNode = id => seedNode(id, seeds) }) {
  identity ??= await throwawayIdentity()
  const status = { photoOnly: true, npub: encodeNpub(identity.xOnlyPubkey), seeds: new Map(), errors: 0, lastError: "" }
  const emit = () => onStatus(status)
  const node = makeNode(identity)
  node.on("peer", p => {
    if (p.remoteAddr?.transport === "websocket") status.seeds.set(p.remoteAddr.addr, p.state)
    emit()
  })
  node.on("error", e => {
    status.errors++
    status.lastError = String(e?.err?.message ?? e).slice(0, 160)
    emit()
  })
  const blobs = new MeshBlobClient(node, identity.publicKey, { allow: k => isOwner(getPhotoVaults(), k) })
  status.blobs = blobs.stats
  await node.start()
  const statsTimer = setInterval(emit, 1000)
  emit()
  return {
    node,
    status,
    /** A blob from a photo address by sha256: { bytes, type }, hash-checked. Any other vault is refused. */
    getBlob: (vault, sha256, opts) => blobs.get(vault, sha256, opts),
    stop: async () => {
      clearInterval(statsTimer)
      await blobs.stop()
      await node.stop()
    },
  }
}
