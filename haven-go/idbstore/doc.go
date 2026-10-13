// Package idbstore is an eventstore.Store backed by the browser's IndexedDB,
// for running Haven compiled to GOOS=js GOARCH=wasm.
//
// Each event is one record keyed by its id. The record keeps the raw JSON
// (decoded with go-nostr's easyjson on the way out) next to the fields the
// indexes need:
//
//	created_at  [ca]           everything, newest first
//	kind        [k, ca]        kinds-only filters
//	author      [pk, ca]       authors-only filters
//	author+kind [pk, k, ca]    authors x kinds filters
//	tag         [[n, v, ca]]   multiEntry, one key per distinct tag name+value
//
// A filter is split into one range per combination of its values (every
// author x every kind, or every value of the chosen tag), each range is walked
// newest-first, and every candidate is checked with filter.Matches before it
// is kept, so multi-key filters match every combination and nothing more.
//
// Limits follow eventstore/badger, which is what Haven runs on the phones: a
// limit above MaxLimit is not clamped down to MaxLimit, it falls back to
// MaxLimit/4, the same as asking for no limit.
package idbstore
