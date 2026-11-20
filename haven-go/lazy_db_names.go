//go:build !wasm

package main

// lazyDBNames open on first use (lazy_db.go). Each is read rarely or never
// in an ordinary session: the owner's private notes, imported list
// versions, and the media file notes. On a box with a fresh vault these
// held under 40 KB each (RESEARCH/NV_WEB_LINUX_PERF_AUDIT_2026_11_20.md L6).
// inbox, outbox, feed and lists are read at startup, chat by the
// stored-signature probe on the first event, and blossom by the file-note
// backfill and every blob request, so they open with the relay (an upload
// should not pay a store's open, mesh_door_test TestMeshUploadAllocation).
var lazyDBNames = []string{"private", "listsimport", "files"}
