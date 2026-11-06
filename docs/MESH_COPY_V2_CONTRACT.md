# Mesh vault copy v2 contract (first copy = the backup zip over the mesh)

Device **B** (new) copies device **A**'s vault over the mesh. The first copy is the same zip Settings › Back up
writes, served in hash-checked chunks. After that, an automatic catch-up runs on every reconnect. The plan and its
reasoning are in `RESEARCH/NV_MESH_VAULT_COPY_CONTRACT_V2_ZIP_2026_11_05.md` (Tim). This file is the wire contract.
When the prose and the fixtures disagree, **the fixtures win**.

| Side | Code | Tests |
|---|---|---|
| Engine (A and B) | `haven-go/copyv2_*.go` | `haven-go/copyv2_*_test.go`, which read every fixture below |
| iPhone / iPad / Mac | start, progress, settings mapping (Apple lane) | MediaLogicTests read the same fixtures |
| Android | the same (Android lane) | JVM tests read the same fixtures |

Fixtures: `docs/fixtures/mesh-copy/`. No real key, account or device is in them; every hex value is made up.

Logen's picks (2026-11-05), binding:
1. Settings **stay synced** after the first copy: the allowlisted file, newest change wins, carried by the catch-up.
2. The **same zip copy** is used when B is a Mac or a home vault.
3. Old backup zips still import, unchanged.
4. A refused (unsafe) settings file is skipped and the copy finishes without it.
5. A deletes the copy zip after B is done.
6. Media means **the owner's own files**: everything under a record by the vault's own keys, including what he saved
   or mirrored (Logen, 2026-11-05). Photos other people only sent him never land in B's vault (§4).
7. DMs stay encrypted in transit and are decrypted only on B.

## 1. Where it is served

- `/copy/v2/*` is served on the relay handler that **the owner's own devices reach over the mesh**.
  - iPhone: the own port, `HAVEN_MESH_OWN_PORT`.
  - Mac, Android and the box: their relay port, which the mesh hands only to My Devices.
- The **door** (`mesh_door.go`, what strangers reach) never serves it. Any `/copy/` path there is 404.
- Only requests from **loopback** are answered, which is how the mesh hands the own devices this port. Mac, Android
  and the box also listen on the LAN (`RELAY_BIND_ADDRESS` defaults to `0.0.0.0`), so a request from any other
  address is 404. The box's havend forwards to the engine over loopback and names the real client in
  `X-Forwarded-For`. Every hop named there (and in `X-Real-Ip`) must be loopback too, and any `Forwarded` header
  is 404.
- Requests a public tunnel forwarded (Cloudflare headers) are 404.
- Being on that port is not proof of ownership. Every request is authenticated as in §2.

## 2. Authentication

**The mesh never uses the account key** (Logen, 2026-11-06). The copy start and Blossom over the mesh are signed by the
device's **own mesh key**, and a vault accepts one only when that key is in its **paired-device set**. No owner NIP-98,
no nsec anywhere on the mesh.

**The paired-device set.** Both sides already store each other's mesh npub at pairing (iOS My Devices, Android
`fipsPeers` + labels with `linkedBy`). The app hands the set to the engine at start and on every change, the same way
it passes `own_devices` to FIPS: the owner's devices only (`linkedBy` is the owner or empty), roles kept. Old
link-paired devices are in it too. No re-pair is needed.

```
SetMeshDevicesC({"self": "<this vault's mesh npub>", "devices": [{"npub": "<mesh npub>", "role": "phone"}, …]})
```
- 0 set; 1 bad input, and the old set is kept.
- The vault's own key is never a paired device.
- An **empty or missing set accepts no device**. There is no fallback to "anyone".
- **Unpair:** a device that leaves the set loses its copy tokens at once (as `RevokeCopyTokensC`).

**Start.** `POST /copy/v2/start` with `Authorization: Nostr <base64 kind 27235>` (NIP-98), signed by **B's mesh key**:
- `["u", <any scheme://host:port>/copy/v2/start]`. The path is checked. The host is not, because A and B name the
  same mesh link by different loopback addresses.
- `["method","POST"]`.
- `["p", <A's own mesh npub>]` (npub or 64 hex). A proof naming another vault is 401, so it cannot be replayed
  against another of the owner's vaults.
- `created_at` within 60 s of A's clock.
- The event id is used once. A replay is 401.
- The signer is in A's paired set and is not A. Anyone else is 403.
- The token is **bound to the signer**. A `device` tag is not needed; if present it must equal the signer (401).

**Old form, kept until every app sends the device form** (marked `TODO(mesh-key)` in the engine, then removed): the
owner signs, with `["device", <B's own mesh npub>]` instead of `p`; a proof without it is 401.

If the check fails: 401 for a missing, bad, stale, replayed or misaddressed proof; 403 for a valid proof from a key
that is neither a paired device nor (old form) the owner.

### 2.1 Blossom over the mesh (upload, get / check, delete)

A paired device's Blossom request, on the door or on the own-device port, carries a kind 24242 signed by **its mesh
key**:
- `["t", "upload" | "get" | "delete"]`: exactly one, and it must match the request (PUT/HEAD `/upload` is upload,
  GET/HEAD `/<sha256>` is get, DELETE `/<sha256>` is delete). Nothing else (list, mirror, …) is allowed: 403.
- `["x", <sha256>]` for **each** blob acted on, no wildcard and no `server` tag stand-in. An upload whose body hashes
  to no `x` is refused.
- `["p", <receiver's mesh npub>]`. Delete everywhere is either one token per target or one event with several `p`
  tags; each vault checks it is named.
- `["expiration", <unix>]`, in the future and **at most 5 minutes** ahead.
- `created_at` no further ahead than the usual 10-minute future skew.

The vault checks: the signer is in its paired set and is not itself; it is named in `p`; the token is unexpired and
short-lived; and the id has **not been seen before it expires** (no replay: 409, sign a new one). HEAD requests
(the upload pre-flight and the check after a delete) change nothing and do not spend the token.

**Records are filed under the owner.** A device's upload is indexed under the owner's pubkey, never the device key,
so §4 and `copyOwnMediaSet` count it. A device's delete removes only the owner's record: a blob whose records are by
another key stays.

The owner-signed 24242 keeps working until the apps switch (`TODO(mesh-key)`).

**Answer:**
```json
{"id": "<32 hex>", "token": "<64 hex>", "state": "building"}
```
- `token` is a random 32-byte bearer, shown only in this answer. A keeps only its sha256, in
  `copy_tokens.json` (0600).
- Every later `/copy/v2/<id>…` and `/copy/v2/sync/…` request carries `Authorization: Bearer <token>`.
- A token stops working when:
  - the owner removes B from My Devices on A: the app calls `RevokeCopyTokensC(<B's mesh npub or hex>)`
    (0 revoked, 1 none held). That drops B's tokens and the copies they could read, on disk too;
  - B starts again: one token per device, so a new start replaces that device's old token and its copy;
  - it has been unused for 30 days;
  - A's owner changes;
  - B leaves A's paired set (`SetMeshDevicesC`), the same as Remove device.
- Removing B on B's side forgets A: no resume, no catch-up.

## 3. The first copy

1. **B starts.** `POST /copy/v2/start` (§2). A answers at once and builds in the background.
2. **A builds**, into its cache directory as `copy-<id>/`:
   - **`notes.zip`**: the backup writer's zip (`<store>.jsonl` for every store, as stored, so gift wraps and
     private and chat events stay encrypted), with two differences:
     - `blossom.jsonl` carries only the records of the files in `media.zip`;
     - `settings.json` is added when A has one and it passes §5.
   - **`media.zip`**: the owner's own files (§4), each as `media/<sha256>` in the stored form (no compression).
   - `manifest.json`: §3.1.
   - Every part is written as `<name>.partial` and renamed when complete. A part that is visible is a whole part.
   - Before building, A checks free space for roughly the size of the stores plus the media. Short of that, the
     state is `failed` with `no_space`.
3. **B polls** `GET /copy/v2/<id>` until `state` is `ready` (or `failed`).
4. **B fetches** each chunk: `GET /copy/v2/<id>/<part>` with `Range: bytes=<a>-<b>`, one chunk per request.
   - A answers 206 with exactly those bytes.
   - 416 means the range is outside the part, or not a whole chunk.
   - 409 means A is still building.
5. **B checks** each chunk's sha256 against the manifest and writes it at its offset in `copy-<id>/<part>.partial`.
   It records the chunk in the state file (§3.2).
6. **B restores `notes`** first, once that part is whole and its sha256 matches. It uses the normal restore: owner
   check, author filters, deletions, blob records, bad lines counted.
7. **B restores `media`.** Each `media/<sha256>` is hash-checked, then stored. Its record is restored only when the
   file is.
8. **B applies settings.** The engine leaves the checked `settings.json` for the app, at `copy-settings.json` in
   B's relay root (the parent of `DATABASE_PATH`, the folder holding `.env`; Apple: `haven_database/copy-settings.json`),
   and the app applies it (§5).
9. **Relays.** The relay import job then runs as in setup, for anything A lacked.
10. **Done.** B calls `POST /copy/v2/<id>/done`. A deletes `copy-<id>/`, now or 24 h after the build, whichever
    comes first. B deletes its parts once they are restored.

### 3.1 Manifest (`GET /copy/v2/<id>`)

```json
{"v": 2, "id": "…", "state": "building|ready|failed", "error": "",
 "owner": "<hex>", "created_at": 1767000000,
 "progress": {"stores_done": 3, "stores_total": 9, "files_done": 10, "files_total": 40},
 "counts": {"outbox": 21000, "chat": 300}, "files": {"count": 40, "bytes": 123456789},
 "settings": "included|none|refused",
 "parts": [{"name": "notes", "size": 9000000, "sha256": "…", "chunk": 4194304, "chunks": ["…", "…", "…"]},
           {"name": "media", "size": 0, "sha256": "…", "chunk": 4194304, "chunks": []}],
 "zip_key": "<sha256 of the parts' sha256 values, joined in order with \"\\n\">"}
```

**B accepts a ready manifest only when** (`manifest-v2-cases.json`):
- `v` is 2;
- `owner` is B's owner;
- the parts are `notes`, then optionally `media`, each once;
- `chunk` is 4194304;
- every sha256 is 64 lower-case hex;
- `len(chunks) == ceil(size / chunk)`;
- `zip_key` matches the parts.

Anything else is refused, with the error the fixture names.

### 3.2 Resume (`chunk-state-cases.json`)

B's state file `copy-<id>.state.json` holds:
```json
{"v": 1, "id": "…", "zip_key": "…", "done": {"notes": [0, 1], "media": []}, "failures": {"notes:2": 1}}
```

- **A rebuilt zip** (A's copy expired): when a new manifest's `zip_key` differs from the state's, B throws away every
  part and starts over (`restart`).
- **Resuming:** otherwise B fetches only the chunks not in `done`.
- **Bad chunks:** a chunk that fails its hash is fetched again. Its 3rd failure stops the copy with `hash_mismatch`.
- **Whole parts:** once a part is whole, B checks its sha256. On a mismatch, B clears that part's chunks and fetches
  it once more. A second mismatch is `hash_mismatch`.
- **Restores re-run safely:** everything dedupes by event id and sha256.

### 3.3 Progress lines (`progress-v2-lines.json`)

The engine logs one line per step, which every app parses:
```
COPY stage=<building|fetching|restoring|relays|done|failed> part=<notes|media|-> bytes=<n>/<n> items=<n>/<n> source=<mesh|relays> [error=<code>]
```

- Keys are in that order. Unknown keys after them are ignored.
- `error` is present only on `stage=failed`, and on `done` when settings were refused (`error=settings_refused`).
- On `stage=failed ... error=needs_space`, `bytes=<free>/<need>` carries B's free bytes and the need (parts + restored + 1 GB), so the app words "Needs <need> free, this device has <free>" without measuring.

## 4. Media: the owner's own files

**The rule (Logen, 2026-11-05):** anything the owner saved or mirrored counts as his, with no label. A file goes into
`media.zip`, and into catch-up's `sync/files`, when its blob record (kind 24242) is by **one of this vault's own
keys** (the owner and any added accounts). That covers:
- uploads made while posting;
- drafts and other files never posted;
- encrypted DM files the owner sent;
- other people's photos the owner saved or mirrored:
  - iOS: `MediaBackupActions.saveToVault` (`SourceIndicatorView.swift:221`) and the media grid's mirror
    (`MediaGridItem.swift:197`);
  - Android: `BlossomService.mirrorUrlToLocal`, from the feed viewer, Profile › Save to vault and pasted links
    (`FeedMediaMirrorViewModel.kt:103`, `ProfileViewModel.kt:795`, `MediaGalleryViewModel.kt:334`).

Which notes name a file does not matter.

**Left out:** a file whose record is by any other key, even when an own note names it.

**Photos other people only sent the owner are not in A's store.** Every way a file gets into A's Blossom store needs
a record by one of the vault's own keys:
- an upload is refused unless its kind 24242 is signed by a whitelisted key, or by a paired device's mesh key, whose
  upload is then filed under the owner (§2.1; `init.go` `RejectUpload`, `mesh_devices.go` `meshOwnerIndex`; the mesh
  door checks the same, `mesh_door.go` `meshUploadAuthorized`);
- a restore keeps a blob record only from a whitelisted key (`jsonl.go` `importBlobRecord`);
- neither app mirrors received media unprompted: every save or mirror above is an owner action, and the bulk
  `mirrorFromNoteMedia` reads only the owner's own notes;
- a received DM attachment stays on the sender's server until the owner saves it, and once saved it is his.

The record check is therefore the exclusion, and the copy applies it twice: when it reads the blob index
(`copyOwnBlobRecords`) and in the rule itself (`copyOwnMedia`). Fixture: `media-own-uploads-cases.json`.

## 5. Settings (`settings-allowlist.json`, `settings-refuse-cases.json`)

```json
{"v": 1, "updated_at": 1767000000, "keys": {"zaps_only": false, "wot_depth": 2}}
```

- The **app** writes it, mapping its own config to the contract keys in `settings-allowlist.json`. The app writes
  `copy-settings.json` in its data dir whenever a listed setting changes, with `updated_at` = now.
- The **engine** checks it before adding it to a zip or serving it, and again on B before leaving it for the app.

**Refused** (`settings_refused`), with the reason the fixture names:
- `v` is not 1;
- `updated_at` is missing or in the future by more than 10 minutes;
- a key is not in the allowlist;
- a value has the wrong type;
- any string, at any depth, contains (case-insensitive) `nsec1`, `ncryptsec1`, `nostr+walletconnect:` or `bunker:`;
- any string has a run of 64 or more hex digits.

A refused file is never served or applied. The copy goes on without it, and B's last line says
`error=settings_refused`.

**Synced after the first copy (pick 1).** Each catch-up asks `GET /copy/v2/sync/settings` and sends its own with
`PUT /copy/v2/sync/settings`. Newest `updated_at` wins. A tie keeps the receiver's. The winner is written as the
loser's `copy-settings.json`, and its app applies it on change.

**Never in it:**
- nsec, ncryptsec, bunker secrets;
- NWC strings;
- the mesh key;
- My Devices, the device name, the home vault choice.

## 6. Catch-up (every reconnect)

The app calls the engine when a linked device comes into reach. The engine then:

1. **Notes.** For each of `outbox`, `private`, `chat` and `inbox`: `GET /copy/v2/sync/ids?store=<s>&since=<t>`
   (Bearer).
   - The answer is `{ids: [[id, created_at], …], more: bool}`, newest first, at most 5000 per answer.
   - B compares it with its own list for the same window, gets what it lacks (`POST /copy/v2/sync/events {store,
     ids}`, JSONL back), and sends what A lacks (`POST /copy/v2/sync/put?store=<s>`, JSONL body).
   - `since` is the last good catch-up minus 7 days (gift wraps backdate up to 2 days). The first catch-up's `since`
     is the copy's `created_at`.
2. **Every event either side stores from the other** passes the same checks as a restore: id hash, signature,
   author filter per store. An event marked deleted on the receiver is not stored. One that the sender's own
   deletions mark is not sent (fixes #14 and #15).
3. **Media.** `GET /copy/v2/sync/files?since=<t>` lists the owner's own files (§4) added since then. Each missing one is
   fetched with `GET /copy/v2/sync/file/<sha256>` and hash-checked.
4. **Settings** (§5).

This is an id-list diff, not NIP-77. The engine has no owner key to answer NIP-42 for `/private` and `/chat`, so it
uses the copy token on the own-device port instead.

## 7. Errors (`errors-v2.json`)

Every code, where it comes from, and what B does.

| Code | Means | B does |
|---|---|---|
| `auth_refused` | 401 | stops; shows "Couldn't sign in to <name>" |
| `not_owner` | 403 | stops |
| `not_found` | 404 (expired or deleted copy) | starts over |
| `building` | 409 | waits |
| `range` | 416 | refetches by the manifest |
| `no_space` | A is short of disk | falls back to relays and says so |
| `needs_space` | B is short (parts + restored + 1 GB) | stops before fetching; "Needs X GB free, this device has Y" |
| `wrong_owner` | the manifest's owner isn't B's | stops |
| `unsupported_version` | the manifest is `v` > 2 | stops; asks for an update |
| `bad_manifest` | anything else wrong in the manifest | stops |
| `hash_mismatch` | 3 bad tries on one chunk, or a whole part twice | stops; the next reconnect starts over |
| `unreachable` | no link | waits for the next reconnect and resumes |
| `nothing_restored` | the restore stored nothing | shows the error, never "Done" |
| `settings_refused` | §5 | finishes without settings, one line saying so |
| `cancelled` | the user stopped it | keeps the state for a later resume |

## 8. Old backups

A v2 `notes.zip` only adds `settings.json` (plus the trimmed `blossom.jsonl`), which old readers skip
(`jsonl.go importFromZip` reads `.jsonl` entries only). Old backup zips restore unchanged: no settings, no media
part.
