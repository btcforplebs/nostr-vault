# Mesh pairing contract (two-scan device linking)

Linking two of your own devices takes two scans: device **A** shows a code, device **B** scans it and shows its own,
A scans B, and both say "Linked ✓". This file is the wire contract. The pure logic that follows it lives in:

| Platform | Code | Tests |
|---|---|---|
| iPhone / iPad / Mac | `HavenApp/HavenApp/Models/MeshPairing.swift`, `MeshPairingSession.swift`, `MeshPairingWords.swift` | `MediaLogicTests/.../MeshPairingTests.swift` |
| Android | `fips/MeshPairing.kt`, `MeshPairingSession.kt`, `MeshPairingWords.kt` | `test/.../fips/MeshPairingTest.kt` |
| Web | `web-vault/src/net/mesh-pairing.js`, `mesh-pairing-session.js`, `mesh-pairing-words.js` | `web-vault/test/mesh-pairing.test.mjs` |

All three read the same fixtures, `HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing/`
(`payload-cases.json`, `hello-cases.json`, `checkwords-cases.json`, `words.txt`), made by `reference.py` there. Change
the rule in `reference.py` first, regenerate, then make all three agree. The fixture keys are SHA-256 of labels: no
real account or device, and nothing in the fixtures signs.

This layer is pure: no I/O, no keys. Sending and receiving hellos, signing them with the mesh key, NIP-44, the camera
and storing a device belong to each platform's pairing screens, built on top of it.

## 1. The code (QR)

```
nvpair:v1?m=<mesh npub>&n=<name>&r=<role>&o=<owner npub>&s=<secret>      A's code
nvpair:v1?m=<mesh npub>&n=<name>&r=<role>&o=<owner npub>&e=<A's secret>&b=<B's secret>  B's code
```

- Fields are written in that order. `n` is left out when the name is empty.
- `m` is the showing device's **mesh** address (its own key, never the account). `o` is the account it runs as.
- `r` is the wire role: `phone`, `mac`, `homeVault`, `browser` (iOS `MeshDeviceRole` raw values; Android's stored
  `home_vault` is mapped, never sent).
- `s`: 16 random bytes, base64url without padding (22 characters), fresh each time the code is shown. `e`: A's `s`.
  `b`: B's own fresh secret s_B, the same shape. Only a device that read B's code knows s_B, so the scan ack (§3)
  proves A really scanned B. Without it, the device showing the first code could make the ack alone (Tron, PR 1700).
- `n`: trimmed, at most **40 Unicode code points** (a builder cuts it, a reader refuses longer). Percent-encoded as
  UTF-8, every byte outside `A-Z a-z 0-9 - . _ ~` written `%XX` in upper case.
- **No keys in a code, ever**: no nsec, no NWC string.

Reading, in this order (the first that fails is the answer):

| Check | Refusal |
|---|---|
| starts `nvpair:` (any case), after trimming whitespace | `notPairing` |
| version is `v1` | `unsupportedVersion` |
| each field is `k=v`, no key twice, escapes valid UTF-8 | `malformed` |
| `m` is an npub (63 chars, one case, valid checksum, 32 bytes) | `badAddress` |
| `r` is a wire role | `unknownRole` |
| `o` is an npub | `missingOwner` |
| exactly one of `s` / `e`; `b` with `e` and never with `s`; each canonical base64url of 16 bytes | `badCode` |
| `n` ≤ 40 code points | `nameTooLong` |
| `m` is not this device's own mesh address | `ownAddress` |

Unknown extra fields are ignored, so a later v1 can add one.

## 2. Owner and role

- **Owner**: `o` is compared with every account on this device: the active one → `ok`; another one → `switchTo`
  (that account); none → `otherOwner`, and nothing is stored. `o` is a claim; it stops the common accident, not a
  deliberate stranger.
- **Role (Tron 1)**: name, role and owner all come from the other device, and the role grants access, so the person
  confirms the role in plain words before anything is stored (`roleConfirmText`). A device already known under
  another role is refused (`refuseOtherRole`); under the same role it is `alreadyLinked`. Pairing never calls the
  existing add path for a device it would move between roles.

## 3. Hello and ack

Both are the NIP-44 encrypted content of an ephemeral **kind 21195** event, signed by the sender's **mesh key**, `p`
= the other device's mesh pubkey, sent to the finder relays (and the mesh when the other device is already in reach).
The receiver checks the signature and decrypts first; the session only sees the sender's pubkey and the plaintext.

```
hello (B → A)  {"v":1,"s":"<A's secret>","n":"<B name>","r":"<B role>","o":"<B owner npub>","t":<unix>}
ack   (A → B)  {"v":1,"ack":true,"d":"<hex SHA-256(s_A ‖ s_B ‖ m_A ‖ m_B)>"}          scanned B's code
               {"v":1,"ack":true,"d":"<hex SHA-256(s_A ‖ m_A ‖ m_B)>","w":true}  accepted with the check words
```

- Compact JSON in that key order; `n` left out when empty. `t` is an integer.
- `s_A` and `s_B` are the 16 secret bytes, `m_A` and `m_B` the 32-byte mesh pubkeys (A showed first). `d` is
  lower-case hex. A's session builds the right ack itself (`ack` after `confirm`).
- B accepts an ack **without** `w` only with the s_B digest. The digest without s_B counts only with `w`, and then B
  also needs its own words tap. So a device that never read B's code can't link B silently.
- **Resend a hello byte for byte.** The same sender with a changed hello (even a new `t`) aborts the session (Tron 3),
  so a platform that resends must keep the first hello's content.
- `w` (added in phase 0, for Tron 2): A tells B it linked by Accept, not by scanning, so B must also get its own
  "They match" tap before storing. The ack is signed by A's mesh key, which B read from A's code itself.

## 4. Sessions

**A** (`MeshPairingSession`): created with its secret and the time its code was shown.

| Event | Outcome |
|---|---|
| hello, after the session is done or expired | `expired` |
| hello, after an abort | `abort` |
| content is not a hello (bad JSON, `v` ≠ 1, an ack, bad role, name > 40) | `ignore:notHello` |
| sender is this device's own mesh key | `ignore:ownAddress` |
| `s` ≠ the live secret | `ignore:wrongSecret` |
| `t` more than 180 s from now | `ignore:stale` |
| `o` fails the owner check | `refuse:otherOwner` / `refuse:switchTo` (does not abort) |
| first good hello, within 180 s of the code being shown | `camera` |
| first good hello, later | `expired` |
| the same hello again from the same sender (a relay resend) | `ignoreDuplicate` |
| **any other good hello for the same secret (Tron 3)** | `abort`; the session stays aborted |
| B's code before any hello | `reject:notReady` |
| B's code that doesn't read | the parse refusal |
| B's code carries `s` (it's an A code) | `reject:notTheirCode` |
| `e` ≠ the live secret | `reject:echoMismatch` |
| `m` ≠ the hello's sender, or `r` ≠ the hello's role | `reject:notTheDevice` |
| B's code or Accept more than 180 s after the hello | `expired` |
| B's code checks out / Accept | `confirm` with the hello's name and role; the session is done (the code is spent) |

**B** (`MeshPairingJoiner`): created from A's parsed code, its own s_B and the time it scanned A.

| Event | Outcome |
|---|---|
| ack after linking | `ignoreDuplicate` |
| not an ack (`ack` not `true`, `d` not 64 lower-case hex, `w` not a bool) | `ignore:notAck` |
| sender ≠ A's mesh key | `ignore:wrongSender` |
| no `w` and `d` ≠ SHA-256(s_A ‖ s_B ‖ m_A ‖ m_B), or `w` and `d` ≠ SHA-256(s_A ‖ m_A ‖ m_B) | `ignore:badDigest` |
| more than 360 s after the scan | `expired` |
| `w` and B's own tap not yet given | `waitWords` |
| otherwise | `linked` |
| B's own "They match" tap, more than 360 s after the scan | `expired` |
| B's own "They match" tap | `linked` after a `w` ack, else `waitAck` |

Neither side stores anything before its last step: A after `confirm` and the role confirm, B after `linked` and the
role confirm. A cancelled flow leaves no device behind.

## 5. Check words (Accept path, Tron 2/T3)

On a device with no usable camera (the Mac, a browser without one), A can Accept instead of scanning. Both screens
show the same 4 words and the other device's short address (`npub1abc…wxyz`), and each side taps "They match".

- Words: the first 44 bits of SHA-256(m_A ‖ m_B ‖ s_A), big-endian, 11 bits each, indexing the BIP-39 English list
  (`words.txt`, 2048 words, CRC32 `c1dbd296`). A and B compute it with the same order (A is the device that showed
  first), so the words match only for the same pair and the same secret.
- Accept is never offered on phones.

## 6. Timings

| Constant | Seconds | Meaning |
|---|---|---|
| `codeLifetime` | 180 | a hello may open A's camera this long after A's code is shown |
| `scanWindow` | 180 | A must scan B's code (or Accept) this long after the hello |
| `ackWindow` | 360 | B waits this long for the ack after scanning A |
| `helloSkew` | 180 | a hello's own `t` must be this close to the receiver's clock |

The role confirm (Add) has a deadline on both sides, so a pairing never ends linked on one side only
(`MeshPairingConfirmWindow`). A's Add must come within `scanWindow` of the hello (the scan step's countdown carries on);
B's Add, which sends the hello, within `ackWindow` − `scanWindow` − 15 s (relay margin) = 165 s of the scan. An Add past
its deadline fails with the expired text: nothing is stored and no hello or ack is sent.

## 7. Words people read

The role confirm, refusals and outcomes have one wording on every platform, pinned by `payload-cases.json` `texts`:
`roleConfirmText(role, name, setup)`, the refusal lines, "Already linked.", "This code has expired. Show a new one.",
and the abort line. `setup: true` is the first-run "Already using Nostr Vault on another device?" path, which uses no
mesh or role words. An empty name reads "this device".

## 8. The box (Linux home vault)

A box pairs the same way, always as **A** (Desktop Vaults plan §2.3, Tron N1, N4). Its code is shown in the box web UI,
which is already signed in; a phone scans it and sends the hello. The box has no camera, so it can only finish on the
check-words path (§5): the UI shows the 4 words, the device's name and the role confirm (§7), and one tap, "They match"
and Add together, stores the device and sends the `w` ack. The phone then needs its own tap too, as §4 says.

| Side | Code | Tests |
|---|---|---|
| havend (`haven-go/internal/box/`) | `pairing_code.go` (§1), `pairing.go` (§2, §3, §5), `pairing_session.go` (A, §4), `pairing_box.go` (the live flow), `routes_pairing.go` (`/api/box/pair`) | `pairing_test.go` reads the same fixtures: every parse, build, owner, role, builder, shower and check-words case. The joiner cases are the apps' alone: a box never scans. |
| nv-mesh (`linux/mesh/src/dial.rs`) | `pair_open`, `pair_ack` on `dial.sock` | `cargo test` in `linux/mesh` |

What stays where:
- **The mesh key never leaves nv-mesh.** havend runs the session and holds no key. It asks nv-mesh, over `dial.sock`, to
  check and open one kind-21195 event to the box (`pair_open`) and to seal and sign the ack (`pair_ack`). `pair_ack`
  takes exactly `{"v":1,"ack":true,"d":"<64 hex>","w":true}` and nothing else, so the socket cannot get another event
  signed. Neither op needs the other device to be paired: that is the point of pairing.
- **The code names the box as `mac`** (a Desktop Vault: it keeps a full copy, like a Mac), with `o` the account signed in to the box UI (the one that asked for the
  code). The hello's `o` is checked against every account signed in to the box: another one is `switchTo`, as on a
  phone with several accounts.
- **Confirm carries the role shown** (`{"role":"phone"}`), so a confirm never adds a device under another role than the
  hello's. The stored entry keeps the hello's name and role and the account that confirmed it.
- **Stored where:** the box's own paired set, `box/paired-devices.json`. It is seeded once from the devices the box
  trusts today, only after a settled 10063 read and never from an empty result. Before the seed, `mesh-devices.json`
  follows the 10063s; from the seed on, the paired set alone decides who the mesh lets in, and the 10063s are shown
  only as who vouches. **Remove** in the box UI (`POST /api/box/devices/remove`) takes a device out of the set, writes
  `mesh-devices.json` and the engine's file without it at once, and the engine revokes its copy tokens
  (`MESH_COPY_V2_CONTRACT.md` §2: refused on its next copy, after a restart too).
- **Relays:** the hello comes in and the ack goes out on the finder relays (`NV_MESH_RELAYS`, the same three nv-mesh
  and the apps use).
- **Nothing is published** but the ack, and no account key is used anywhere in this flow.
