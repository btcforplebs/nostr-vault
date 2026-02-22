/**
 * Haven Push Proxy — Cloudflare Worker
 *
 * Architecture:
 *  1. The iOS app POSTs its APNs device token + owner npub to /register
 *  2. This worker stores {npub → token} in KV
 *  3. A Durable Object (RelaySubscriber) maintains a persistent WebSocket
 *     connection to public Nostr relays, watching for events p-tagged with
 *     registered npubs
 *  4. When an event arrives, the DO looks up the token and sends a silent
 *     APNs push (content-available: 1) to wake the iOS app
 *
 * Deploy:
 *   1. `npm create cloudflare@latest haven-push`
 *   2. Copy this file to src/index.js
 *   3. Add KV namespace "REGISTRATIONS" in wrangler.toml
 *   4. Add Durable Object "RELAY_SUBSCRIBER" in wrangler.toml
 *   5. Set secrets:
 *      wrangler secret put APNS_KEY_ID       -- your .p8 key ID
 *      wrangler secret put APNS_TEAM_ID      -- your Apple Team ID
 *      wrangler secret put APNS_BUNDLE_ID    -- e.g. com.yourname.haven
 *      wrangler secret put APNS_PRIVATE_KEY  -- entire .p8 file contents
 *   6. `wrangler deploy`
 */

// ─────────────────────────────────────────────────────────────────────────────
// Worker entry point
// ─────────────────────────────────────────────────────────────────────────────

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);

        if (request.method === "POST" && url.pathname === "/register") {
            return handleRegister(request, env);
        }

        if (request.method === "DELETE" && url.pathname === "/unregister") {
            return handleUnregister(request, env);
        }

        // Health check
        if (url.pathname === "/") {
            return new Response("Haven Push Proxy ✓", { status: 200 });
        }

        return new Response("Not Found", { status: 404 });
    },
};

// ─────────────────────────────────────────────────────────────────────────────
// /register  — store npub → device token
// ─────────────────────────────────────────────────────────────────────────────

async function handleRegister(request, env) {
    let body;
    try {
        body = await request.json();
    } catch {
        return new Response("Bad JSON", { status: 400 });
    }

    const { token, npub, platform } = body;
    if (!token || !npub) {
        return new Response("Missing token or npub", { status: 400 });
    }

    // Store token keyed by npub. One npub → one device (overwrite on reinstall).
    await env.REGISTRATIONS.put(`npub:${npub}`, JSON.stringify({ token, platform: platform ?? "apns" }));

    // Tell the Durable Object to subscribe to this npub on Nostr relays.
    const id = env.RELAY_SUBSCRIBER.idFromName("singleton");
    const stub = env.RELAY_SUBSCRIBER.get(id);
    await stub.fetch(new Request("https://internal/subscribe", {
        method: "POST",
        body: JSON.stringify({ npub }),
    }));

    return new Response("OK", { status: 200 });
}

// ─────────────────────────────────────────────────────────────────────────────
// /unregister
// ─────────────────────────────────────────────────────────────────────────────

async function handleUnregister(request, env) {
    let body;
    try { body = await request.json(); } catch { return new Response("Bad JSON", { status: 400 }); }
    if (body.npub) await env.REGISTRATIONS.delete(`npub:${body.npub}`);
    return new Response("OK", { status: 200 });
}

// ─────────────────────────────────────────────────────────────────────────────
// Durable Object: RelaySubscriber
// Maintains persistent WebSocket connections to Nostr relays on behalf of
// all registered npubs.
// ─────────────────────────────────────────────────────────────────────────────

export class RelaySubscriber {
    constructor(state, env) {
        this.state = state;
        this.env = env;
        this.sockets = new Map(); // relay URL → WebSocket
        this.subscribedHexPubkeys = new Set();

        // Public relays to watch for mentions/DMs
        this.relays = [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.wine",
        ];
    }

    async fetch(request) {
        const url = new URL(request.url);

        if (url.pathname === "/subscribe") {
            const { npub } = await request.json();
            const hex = npubToHex(npub);
            if (hex && !this.subscribedHexPubkeys.has(hex)) {
                this.subscribedHexPubkeys.add(hex);
                this.resubscribeAll();
            }
            return new Response("OK");
        }

        return new Response("Not Found", { status: 404 });
    }

    // Open (or reopen) WebSocket connections to all relays with an updated filter.
    resubscribeAll() {
        if (this.subscribedHexPubkeys.size === 0) return;

        for (const relayURL of this.relays) {
            this.connectRelay(relayURL);
        }
    }

    connectRelay(relayURL) {
        // Close stale socket if any
        const existing = this.sockets.get(relayURL);
        if (existing && existing.readyState < 2) {
            try { existing.close(); } catch { }
        }

        const ws = new WebSocket(relayURL);
        this.sockets.set(relayURL, ws);

        ws.addEventListener("open", () => {
            const subId = "haven-push-" + Math.random().toString(36).slice(2, 8);
            const pubkeys = [...this.subscribedHexPubkeys];

            // Subscribe to kind 1 mentions + kind 4 DMs addressed to any registered pubkey
            const filter = {
                kinds: [1, 4],
                "#p": pubkeys,
                since: Math.floor(Date.now() / 1000) - 30, // events in the last 30s + live
            };
            ws.send(JSON.stringify(["REQ", subId, filter]));
        });

        ws.addEventListener("message", async (event) => {
            let msg;
            try { msg = JSON.parse(event.data); } catch { return; }
            if (!Array.isArray(msg) || msg[0] !== "EVENT") return;

            const nostrEvent = msg[2];
            if (!nostrEvent || ![1, 4].includes(nostrEvent.kind)) return;

            // Find which registered pubkey this is addressed to
            const pTags = (nostrEvent.tags || []).filter(t => t[0] === "p");
            for (const [, recipientHex] of pTags) {
                if (!this.subscribedHexPubkeys.has(recipientHex)) continue;

                // Find that pubkey's npub to look up their device token
                const npub = hexToNpub(recipientHex);
                if (!npub) continue;

                const record = await this.env.REGISTRATIONS.get(`npub:${npub}`, { type: "json" });
                if (!record?.token) continue;

                await sendAPNs(this.env, record.token, nostrEvent, recipientHex);
                break; // Only send once per event even if multiple p-tags match
            }
        });

        ws.addEventListener("close", () => {
            // Reconnect after 5 seconds
            setTimeout(() => this.connectRelay(relayURL), 5000);
        });

        ws.addEventListener("error", () => {
            setTimeout(() => this.connectRelay(relayURL), 5000);
        });
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// APNs HTTP/2 push sender
// Uses JWT-based authentication (requires .p8 key, key ID, team ID).
// ─────────────────────────────────────────────────────────────────────────────

async function sendAPNs(env, deviceToken, nostrEvent, recipientHex) {
    const apnsURL = `https://api.push.apple.com/3/device/${deviceToken}`;

    // Build JWT
    const jwt = await buildAPNsJWT(env);

    // Silent push payload — iOS wakes the app via didReceiveRemoteNotification
    const payload = {
        aps: {
            "content-available": 1, // silent push — wakes the app
        },
        eventId: nostrEvent.id,
        kind: nostrEvent.kind,
        pubkey: nostrEvent.pubkey,
    };

    const response = await fetch(apnsURL, {
        method: "POST",
        headers: {
            "Authorization": `Bearer ${jwt}`,
            "apns-push-type": "background",
            "apns-priority": "5", // 5 = low priority for background, 10 = immediate
            "apns-topic": env.APNS_BUNDLE_ID,
            "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
    });

    if (response.status !== 200) {
        const body = await response.text();
        console.error(`APNs rejected push (${response.status}): ${body}`);
    }
}

// JWT cache to avoid signing on every push
let cachedJWT = null;
let jwtGeneratedAt = 0;

async function buildAPNsJWT(env) {
    const now = Math.floor(Date.now() / 1000);
    if (cachedJWT && now - jwtGeneratedAt < 3000) return cachedJWT; // Cache for 50 min

    const header = btoa(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const claims = btoa(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
    const unsigned = `${header}.${claims}`;

    // Import the .p8 EC private key
    const keyData = env.APNS_PRIVATE_KEY
        .replace("-----BEGIN PRIVATE KEY-----", "")
        .replace("-----END PRIVATE KEY-----", "")
        .replace(/\s/g, "");
    const binaryKey = Uint8Array.from(atob(keyData), c => c.charCodeAt(0));
    const cryptoKey = await crypto.subtle.importKey(
        "pkcs8", binaryKey.buffer,
        { name: "ECDSA", namedCurve: "P-256" },
        false, ["sign"]
    );

    const signature = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        cryptoKey,
        new TextEncoder().encode(unsigned)
    );

    const sig = btoa(String.fromCharCode(...new Uint8Array(signature)))
        .replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");

    cachedJWT = `${unsigned}.${sig}`;
    jwtGeneratedAt = now;
    return cachedJWT;
}

// ─────────────────────────────────────────────────────────────────────────────
// Bech32 helpers (npub ↔ hex)
// ─────────────────────────────────────────────────────────────────────────────

const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function npubToHex(npub) {
    try {
        if (!npub.startsWith("npub1")) return null;
        const decoded = bech32Decode(npub);
        return decoded ? uint8ArrayToHex(decoded) : null;
    } catch { return null; }
}

function hexToNpub(hex) {
    try {
        const bytes = hexToUint8Array(hex);
        return bech32Encode("npub", bytes);
    } catch { return null; }
}

function bech32Decode(str) {
    const sep = str.lastIndexOf("1");
    if (sep < 1) return null;
    const data = str.slice(sep + 1).toLowerCase().split("").map(c => CHARSET.indexOf(c));
    if (data.includes(-1)) return null;
    // Verify checksum
    if (!bech32VerifyChecksum(str.slice(0, sep).toLowerCase(), data)) return null;
    // Convert from 5-bit groups to 8-bit
    return convertbits(data.slice(0, -6), 5, 8, false);
}

function bech32Encode(hrp, data) {
    const converted = convertbits(Array.from(data), 8, 5, true);
    const checksum = bech32CreateChecksum(hrp, converted);
    return hrp + "1" + [...converted, ...checksum].map(d => CHARSET[d]).join("");
}

function bech32Polymod(values) {
    const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    let chk = 1;
    for (const v of values) {
        const top = chk >> 25;
        chk = (chk & 0x1ffffff) << 5 ^ v;
        for (let i = 0; i < 5; i++) if ((top >> i) & 1) chk ^= GEN[i];
    }
    return chk;
}

function bech32HrpExpand(hrp) {
    const ret = [];
    for (const c of hrp) ret.push(c.charCodeAt(0) >> 5);
    ret.push(0);
    for (const c of hrp) ret.push(c.charCodeAt(0) & 31);
    return ret;
}

function bech32VerifyChecksum(hrp, data) {
    return bech32Polymod([...bech32HrpExpand(hrp), ...data]) === 1;
}

function bech32CreateChecksum(hrp, data) {
    const values = [...bech32HrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
    const poly = bech32Polymod(values) ^ 1;
    const ret = [];
    for (let i = 0; i < 6; i++) ret.push((poly >> (5 * (5 - i))) & 31);
    return ret;
}

function convertbits(data, fromBits, toBits, pad) {
    let acc = 0, bits = 0;
    const ret = [];
    const maxv = (1 << toBits) - 1;
    for (const value of data) {
        acc = (acc << fromBits) | value;
        bits += fromBits;
        while (bits >= toBits) {
            bits -= toBits;
            ret.push((acc >> bits) & maxv);
        }
    }
    if (pad && bits > 0) ret.push((acc << (toBits - bits)) & maxv);
    return ret;
}

function uint8ArrayToHex(arr) {
    return Array.from(arr).map(b => b.toString(16).padStart(2, "0")).join("");
}

function hexToUint8Array(hex) {
    const result = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) result[i / 2] = parseInt(hex.slice(i, i + 2), 16);
    return result;
}
