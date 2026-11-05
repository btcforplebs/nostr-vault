package main

import (
	"archive/zip"
	"bufio"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/fiatjaf/eventstore"
	"github.com/nbd-wtf/go-nostr"
)

func (z *zipWriter) close() {
	if err := z.w.Close(); err != nil {
		slog.Error("❌ error closing zip writer", "error", err)
	}
	if err := z.f.Close(); err != nil {
		slog.Error("❌ error closing zip file", "error", err)
	}
}

func exportToZip(ctx context.Context, zipFileName string) error {
	slog.Info("🛫 starting export", "file", zipFileName)
	f, err := os.Create(zipFileName)
	if err != nil {
		return fmt.Errorf("error creating zip file: %w", err)
	}

	zw := zip.NewWriter(f)
	z := &zipWriter{f: f, w: zw}
	defer z.close()

	for name, db := range dbs {
		fileName := name + ".jsonl"
		slog.Info("📦 exporting db to fileName", "fileName", fileName)

		header := &zip.FileHeader{
			Name:     fileName,
			Method:   zip.Deflate,
			Modified: time.Now(),
		}

		writer, err := zw.CreateHeader(header)
		if err != nil {
			return fmt.Errorf("error creating zip entry %s: %w", fileName, err)
		}

		if err := exportDB(ctx, db, writer); err != nil {
			return fmt.Errorf("error exporting %s: %w", fileName, err)
		}
	}

	slog.Info("✅ export complete", "file", zipFileName)
	return nil
}

func exportToJSONL(ctx context.Context, relayName, jsonlFileName string) error {
	slog.Info("🛫 starting export", "relay", relayName, "file", jsonlFileName)
	db, ok := dbs[relayName]
	if !ok {
		return fmt.Errorf("unknown relay: %s", relayName)
	}

	f, err := os.Create(jsonlFileName)
	if err != nil {
		return fmt.Errorf("error creating jsonl file: %w", err)
	}
	defer func() {
		if err := f.Close(); err != nil {
			slog.Error("❌ error closing jsonl file", "error", err)
		}
	}()

	if err := exportDB(ctx, db, f); err != nil {
		return fmt.Errorf("error exporting %s: %w", relayName, err)
	}

	slog.Info("✅ export complete", "file", jsonlFileName)
	return nil
}

// errNotYourBackup: the zip's own notes (outbox, lists) hold nothing signed
// by this vault's owner, so it is someone else's backup.
var errNotYourBackup = errors.New("this backup holds no notes by this account")

// errNothingRestored: the zip held no store this vault knows, or none of its
// events could go in.
var errNothingRestored = errors.New("nothing in this backup could be restored")

// importStats counts one restore. stored + dup is what the vault now holds
// from the backup; skipped are lines refused on purpose (forged, someone
// else's, deleted, ephemeral); bad are lines that would not parse or store.
type importStats struct {
	stored, dup, skipped, bad int
}

func (a *importStats) add(b importStats) {
	a.stored += b.stored
	a.dup += b.dup
	a.skipped += b.skipped
	a.bad += b.bad
}

func importFromZip(ctx context.Context, zipFileName string) error {
	slog.Info("🛬 starting import", "file", zipFileName)

	// Only the owner's own backup (Setup and Settings alike). The check reads
	// the zip's outbox and lists, never feed or inbox, which hold other
	// people's notes by design.
	if config.OwnerPubKey != "" {
		ours, err := zipHasEventBy(zipFileName, config.OwnerPubKey)
		if err != nil {
			return err
		}
		if !ours {
			return errNotYourBackup
		}
	}

	zipFile, err := zip.OpenReader(zipFileName)
	if err != nil {
		return fmt.Errorf("error opening zip file: %w", err)
	}
	defer func() {
		if err := zipFile.Close(); err != nil {
			slog.Error("❌ error closing zip file", "error", err)
		}
	}()

	// One store failing doesn't stop the others: entry order is random, so
	// stopping would drop a random set of stores.
	var total importStats
	var errs []error
	known := 0
	for _, file := range zipFile.File {
		if !strings.HasSuffix(file.Name, ".jsonl") {
			slog.Warn("⏭️ skipping unknown file in zip", "file", file.Name)
			continue
		}
		relayName := strings.TrimSuffix(file.Name, ".jsonl")
		db, ok := dbs[relayName]
		if !ok {
			slog.Warn("⏭️ skipping file for unknown relay type", "file", file.Name)
			continue
		}
		known++

		slog.Info("📦 importing file to db", "file", file.Name)

		st, err := importEntry(ctx, db, file)
		total.add(st)
		if err != nil {
			slog.Error("❌ store not fully restored", "file", file.Name, "error", err)
			errs = append(errs, err)
		}
	}

	slog.Info("📥 restore totals", "stored", total.stored, "duplicates", total.dup, "skipped", total.skipped, "bad", total.bad, "failed_stores", len(errs))
	if known == 0 || total.stored+total.dup == 0 {
		return errors.Join(append([]error{errNothingRestored}, errs...)...)
	}
	if len(errs) > 0 {
		return errors.Join(errs...)
	}
	slog.Info("✅ import complete", "file", zipFileName)
	return nil
}

func importEntry(ctx context.Context, db DBBackend, file *zip.File) (importStats, error) {
	rc, err := file.Open()
	if err != nil {
		return importStats{}, fmt.Errorf("error opening zip entry %s: %w", file.Name, err)
	}
	defer func() {
		if err := rc.Close(); err != nil {
			slog.Error("❌ error closing zip entry", "file", file.Name, "error", err)
		}
	}()

	st, err := importDBStats(ctx, db, rc)
	if err != nil {
		return st, fmt.Errorf("error importing %s: %w", file.Name, err)
	}
	return st, nil
}

func importFromJSONL(ctx context.Context, relayName, jsonlFileName string) error {
	slog.Info("🛬 starting import", "relay", relayName, "file", jsonlFileName)
	db, ok := dbs[relayName]
	if !ok {
		return fmt.Errorf("unknown relay: %s", relayName)
	}

	f, err := os.Open(jsonlFileName)
	if err != nil {
		return fmt.Errorf("error opening jsonl file: %w", err)
	}
	defer func() {
		if err := f.Close(); err != nil {
			slog.Error("❌ error closing jsonl file", "error", err)
		}
	}()

	if err := importDB(ctx, db, f); err != nil {
		return fmt.Errorf("error importing %s: %w", relayName, err)
	}

	slog.Info("✅ import complete", "file", jsonlFileName)
	return nil
}

type zipWriter struct {
	f *os.File
	w *zip.Writer
}

func importDB(ctx context.Context, db DBBackend, r io.Reader) error {
	_, err := importDBStats(ctx, db, r)
	return err
}

// importDBStats restores one store's lines. A line that won't parse or store
// is counted and passed over; only a read error ends the store early.
func importDBStats(ctx context.Context, db DBBackend, r io.Reader) (importStats, error) {
	scanner := bufio.NewScanner(r)
	// Nostr events can be large, increase buffer size if necessary.
	// Default is 64KB, which might be enough for most events, but let's be safe.
	const maxCapacity = 100 * 1024 * 1024 // 100MB
	buf := make([]byte, 64*1024)
	scanner.Buffer(buf, maxCapacity)

	var st importStats
	now := time.Now()
	for scanner.Scan() {
		var event nostr.Event
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			slog.Warn("⏭️ skipping a line that isn't an event", "error", err)
			st.bad++
			continue
		}
		switch importOne(ctx, db, &event, now) {
		case importStored:
			st.stored++
		case importDup:
			st.dup++
		case importSkipped:
			st.skipped++
		case importBad:
			st.bad++
		}
	}

	slog.Info("📥 imported events", "count", st.stored, "duplicates", st.dup, "skipped", st.skipped, "bad", st.bad)
	return st, scanner.Err()
}

type importOutcome int

const (
	importStored importOutcome = iota
	importDup
	importSkipped
	importBad
)

func importOne(ctx context.Context, db DBBackend, event *nostr.Event, now time.Time) importOutcome {
	// The blob index (blossom.jsonl) is the relay's own unsigned kind 24242
	// records (khatru EventStoreBlobIndexWrapper.Keep): checked on their own
	// terms, not dropped for having no signature.
	if blossomDB != nil && db == blossomDB {
		return importBlobRecord(ctx, db, event, now)
	}
	if !importable(event, now) {
		slog.Warn("⏭️ skipping unsigned, altered or future-dated event", "id", event.ID)
		return importSkipped
	}
	if nostr.IsEphemeralKind(event.Kind) {
		return importSkipped
	}
	// The list history keeps every version: replacing would collapse a
	// restored history to one copy per list.
	if listsDB != nil && db == listsDB {
		if !isOwnerList(event) {
			return importSkipped
		}
		if err := recordListVersion(ctx, db, event); err != nil {
			if errors.Is(err, errFutureEvent) {
				return importSkipped
			}
			slog.Warn("⏭️ list version not restored", "id", event.ID, "error", err)
			return importBad
		}
		return importStored
	}
	// So do the versions an import filed (list_history_import.go).
	if listsImportDB != nil && db == listsImportDB {
		if !isOwnerList(event) {
			return importSkipped
		}
		if err := fileImportedVersion(ctx, event); err != nil {
			slog.Warn("⏭️ imported list version not restored", "id", event.ID, "error", err)
			return importBad
		}
		return importStored
	}
	if !restoreAccepts(ctx, db, event) {
		slog.Debug("⏭️ skipping an event this store only takes from the owner", "id", event.ID)
		return importSkipped
	}
	// NIP-09: a deleted event doesn't come back with an old backup.
	if isDeleted(ctx, db, event) || (outboxDB != nil && db != outboxDB && isDeleted(ctx, outboxDB, event)) {
		slog.Debug("⏭️ skipping deleted event", "id", event.ID)
		return importSkipped
	}

	var err error
	// A backup may hold an older copy of a list than the vault: only the
	// newest copy of a replaceable kind is kept (ReplaceEvent), the
	// same rule the relay applies to a live publish.
	if isUserList(event) {
		err = db.ReplaceEvent(ctx, event)
	} else {
		err = db.SaveEvent(ctx, event)
	}
	switch {
	case err == nil:
	case errors.Is(err, eventstore.ErrDupEvent):
		slog.Debug("⏭️ skipping duplicate event", "id", event.ID)
		return importDup
	case errors.Is(err, errFutureEvent):
		return importSkipped
	default:
		slog.Warn("⏭️ event not restored", "id", event.ID, "error", err)
		return importBad
	}
	applyImportedDeletion(ctx, db, event)
	return importStored
}

// restoreAccepts: the owner's stores (outbox, private) take only the
// vault's own keys' events, and the inbox only events for them, as the web
// restore does (web-vault/src/net/backup.js DATABASES). Feed and chat hold
// other people's events by design.
func restoreAccepts(ctx context.Context, db DBBackend, event *nostr.Event) bool {
	switch {
	case db == nil:
		return false
	case outboxDB != nil && db == outboxDB, privateDB != nil && db == privateDB:
		_, ok := config.WhitelistedPubKeys[event.PubKey]
		return ok
	case inboxDB != nil && db == inboxDB:
		// The inbox's own write rule: tags one of the vault's keys, or is the
		// owner's delete request.
		reject, _ := MustTagWhitelistedPubKey(ctx, event)
		return !reject
	}
	return true
}

// importBlobRecord restores one blob index record: kind 24242, an id that
// matches its content, a whitelisted uploader (only they can upload), a
// 64-hex x tag, a plain media type, a size, and not dated in the future.
// The record is unsigned, so the backup only supplies those values: what
// goes in is rebuilt in Keep's exact shape (x, type, size in that order),
// because khatru's parseEvent reads Tags[0..2] by position and panics on
// anything shorter. Kept once per uploader and hash, as Keep does.
func importBlobRecord(ctx context.Context, db DBBackend, event *nostr.Event, now time.Time) importOutcome {
	if event.Kind != 24242 || !event.CheckID() || !event.CreatedAt.Time().Before(now.Add(importFutureSlack)) {
		return importSkipped
	}
	if _, ok := config.WhitelistedPubKeys[event.PubKey]; !ok {
		return importSkipped
	}
	record, ok := rebuildBlobRecord(event)
	if !ok {
		return importSkipped
	}
	event = record
	ch, err := db.QueryEvents(ctx, nostr.Filter{Authors: []string{event.PubKey}, Kinds: []int{24242}, Tags: nostr.TagMap{"x": []string{event.Tags[0][1]}}, Limit: 1})
	if err != nil {
		return importBad
	}
	exists := false
	for range ch {
		exists = true
	}
	if exists {
		return importDup
	}
	if err := db.SaveEvent(ctx, event); err != nil {
		if errors.Is(err, eventstore.ErrDupEvent) {
			return importDup
		}
		slog.Warn("⏭️ blob record not restored", "id", event.ID, "error", err)
		return importBad
	}
	return importStored
}

// rebuildBlobRecord returns the record Keep would have written for the
// x/type/size values in event, or false when one is missing or malformed.
func rebuildBlobRecord(event *nostr.Event) (*nostr.Event, bool) {
	value := func(name string) (string, bool) {
		var found string
		n := 0
		for _, tag := range event.Tags {
			if len(tag) >= 1 && tag[0] == name {
				if len(tag) != 2 {
					return "", false
				}
				found = tag[1]
				n++
			}
		}
		return found, n == 1
	}
	x, ok := value("x")
	if !ok || !isBlobHash(x) {
		return nil, false
	}
	mimeType, ok := value("type")
	if !ok || !isRestorableBlobType(mimeType) {
		return nil, false
	}
	size, ok := value("size")
	if !ok {
		return nil, false
	}
	n, err := strconv.Atoi(size)
	if err != nil || n < 0 || strconv.Itoa(n) != size {
		return nil, false
	}
	record := &nostr.Event{
		PubKey:    event.PubKey,
		Kind:      24242,
		Tags:      nostr.Tags{{"x", x}, {"type", mimeType}, {"size", size}},
		CreatedAt: event.CreatedAt,
	}
	record.ID = record.GetID()
	return record, true
}

// activeBlobTypes are media types a browser runs as a page or script. The
// type picks the extension in a blob's URL, which picks the Content-Type it
// is served with, so a restored record must not turn a stored file into one.
var activeBlobTypes = map[string]bool{
	"text/html":              true,
	"application/xhtml+xml":  true,
	"image/svg+xml":          true,
	"text/javascript":        true,
	"application/javascript": true,
	"text/xml":               true,
	"application/xml":        true,
}

// isRestorableBlobType accepts the types Keep writes: empty, or a plain
// type/subtype (Keep stores mime.TypeByExtension, which may add a charset)
// that is not an active document type.
func isRestorableBlobType(t string) bool {
	if t == "" {
		return true
	}
	if len(t) > 255 {
		return false
	}
	mediaType, params, err := mime.ParseMediaType(t)
	if err != nil || !strings.Contains(mediaType, "/") || activeBlobTypes[mediaType] {
		return false
	}
	for k := range params {
		if k != "charset" {
			return false
		}
	}
	return true
}

func isBlobHash(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// importFutureSlack is how far past now a backup event may be dated. A real
// export holds nothing later than the moment it was made; a little slack
// covers clock skew between the device that wrote it and this one.
const importFutureSlack = 24 * time.Hour

// importable reports whether a backup line may go into the vault: its id
// must match its content, its signature must be valid for its pubkey, and
// it must not be dated in the future. A backup file is not trusted: without
// these, a crafted file could plant an owner follow list (the Web of Trust)
// dated years ahead, or notes and DMs as anyone.
func importable(ev *nostr.Event, now time.Time) bool {
	if !ev.CheckID() {
		return false
	}
	if ok, err := ev.CheckSignature(); err != nil || !ok {
		return false
	}
	return ev.CreatedAt.Time().Before(now.Add(importFutureSlack))
}

// ownNotesEntries are the zip entries that hold the account's own notes.
// Feed and inbox are other people's notes by design, so a single note of
// yours there (a follower's backup) says nothing about whose backup it is.
var ownNotesEntries = map[string]bool{"outbox.jsonl": true, "lists.jsonl": true}

// zipHasEventBy reports whether a backup zip's own notes (outbox, lists)
// hold at least one importable event signed by pubkey. Restore uses it to
// refuse someone else's backup.
func zipHasEventBy(zipFileName, pubkey string) (bool, error) {
	zipFile, err := zip.OpenReader(zipFileName)
	if err != nil {
		return false, fmt.Errorf("error opening zip file: %w", err)
	}
	defer zipFile.Close()

	now := time.Now()
	for _, file := range zipFile.File {
		if !ownNotesEntries[file.Name] {
			continue
		}
		found, err := entryHasEventBy(file, pubkey, now)
		if err != nil {
			return false, err
		}
		if found {
			return true, nil
		}
	}
	return false, nil
}

func entryHasEventBy(file *zip.File, pubkey string, now time.Time) (bool, error) {
	rc, err := file.Open()
	if err != nil {
		return false, fmt.Errorf("error opening zip entry %s: %w", file.Name, err)
	}
	defer rc.Close()

	scanner := bufio.NewScanner(rc)
	scanner.Buffer(make([]byte, 64*1024), 100*1024*1024)
	for scanner.Scan() {
		var event nostr.Event
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			continue // a bad line is passed over here as in the restore
		}
		if event.PubKey == pubkey && importable(&event, now) {
			return true, nil
		}
	}
	return false, scanner.Err()
}

func exportDB(ctx context.Context, db DBBackend, w io.Writer) error {
	const limit = 1000
	var lastTimestamp nostr.Timestamp
	count := 0

	var eventBuffer []*nostr.Event

	flushBuffer := func() error {
		for _, e := range eventBuffer {
			if _, err := fmt.Fprintln(w, e); err != nil {
				return err
			}
			count++
		}
		eventBuffer = eventBuffer[:0]
		return nil
	}

	// drainSecond adds every event stamped ts to the buffer (which holds that
	// second's events so far) and flushes it. The query runs as a negentropy
	// session, whose cap is the store's large negentropy limit rather than
	// the REQ cap.
	drainSecond := func(ts nostr.Timestamp) error {
		events, err := db.QueryEvents(eventstore.SetNegentropy(ctx), nostr.Filter{Since: &ts, Until: &ts})
		if err != nil {
			return err
		}
		for event := range events {
			if event.CreatedAt != ts {
				continue
			}
			pos, found := slices.BinarySearchFunc(eventBuffer, event, func(a, b *nostr.Event) int {
				return cmp.Compare(a.ID, b.ID)
			})
			if !found {
				eventBuffer = slices.Insert(eventBuffer, pos, event)
			}
		}
		if g, ok := db.(*gatedDB); ok && g.isClosing() {
			return errDBClosing
		}
		return flushBuffer()
	}

	for {
		filter := nostr.Filter{
			Limit: limit,
		}
		if lastTimestamp != 0 {
			filter.Until = &lastTimestamp
		}

		events, err := db.QueryEvents(ctx, filter)
		if err != nil {
			return err
		}

		initialCount := count
		initialBufferSize := len(eventBuffer)
		pageHadEvents := false

		for event := range events {
			pageHadEvents = true
			if len(eventBuffer) > 0 && event.CreatedAt != eventBuffer[0].CreatedAt {
				if err := flushBuffer(); err != nil {
					return err
				}
			}

			// Insert into eventBuffer maintaining ID order and skipping duplicates.
			// This works around eventstore LMDB backend that don't guarantee NIP-01
			// REQ order when paginating with a limit.
			//
			// This ensures that:
			// 1. Identical JSONL exports are produced (checksum guarantee) regardless of the
			//    underlying DB implementation.
			// 2. Roundtrip consistency is maintained when importing back into a DB, even
			//    if the original source had duplicates (e.g. due to bugs in older versions
			//    of eventstore and khatru).
			pos, found := slices.BinarySearchFunc(eventBuffer, event, func(a, b *nostr.Event) int {
				return cmp.Compare(a.ID, b.ID)
			})
			if !found {
				eventBuffer = slices.Insert(eventBuffer, pos, event)
			} else {
				slog.Debug("⏭️ skipping duplicated event", "id", event.ID)
			}

			lastTimestamp = event.CreatedAt
		}

		// Close cuts an open query short without an error; a short page
		// would read as the end of the database and save a partial backup.
		if g, ok := db.(*gatedDB); ok && g.isClosing() {
			return errDBClosing
		}

		if count == initialCount && len(eventBuffer) == initialBufferSize {
			if !pageHadEvents {
				break
			}
			// Nothing new, yet the page wasn't empty: the whole page is one
			// second (at least `limit` events stamped lastTimestamp). Paging by
			// created_at can't get past it, so read that second on its own,
			// then step to the second before it (web readAll does the same).
			if err := drainSecond(lastTimestamp); err != nil {
				return err
			}
			if lastTimestamp == 0 {
				break
			}
			lastTimestamp--
			if lastTimestamp == 0 {
				// Until=0 would read as "no until"; a second 0 is drained above.
				break
			}
		}
	}

	if err := flushBuffer(); err != nil {
		return err
	}

	slog.Info("📤 exported events", "count", count)

	return nil
}
