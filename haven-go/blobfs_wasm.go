//go:build js && wasm

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall/js"

	"github.com/spf13/afero"
)

// blobFs keeps Blossom's blobs in IndexedDB, so photos and files survive a
// reload. One database per account, "haven:<prefix>:blobs" (storeName), one
// record per blob: key the blob's path, value its bytes. Sign-out deletes it
// with the route stores (web-vault/src/haven/vault.js).
//
// Only paths under prefix (config.BlossomPath, which the blob paths are built
// on by string concatenation) are stored there. Everything else, and the
// ".tmp" file StoreBlob writes before renaming it into place, stays in memory
// as before: the rename is the single IndexedDB put, so an interrupted upload
// leaves nothing behind.
type blobFs struct {
	afero.Fs // memory: directories, temp files, and every path outside prefix
	prefix   string
	name     string
	db       js.Value
}

const blobsRecords = "blobs"

func newBlobFs(name, prefix string) *blobFs {
	return &blobFs{Fs: afero.NewMemMapFs(), prefix: filepath.Clean(prefix), name: name, db: js.Undefined()}
}

// MkdirAll of the blossom path is the first call havenStart makes, and the
// only one whose error it checks, so the database opens here: an unusable
// IndexedDB fails the start instead of quietly losing every blob on reload.
func (f *blobFs) MkdirAll(path string, perm os.FileMode) error {
	if err := f.Fs.MkdirAll(path, perm); err != nil {
		return err
	}
	if filepath.Clean(path) != f.prefix || !f.db.IsUndefined() {
		return nil
	}
	return f.open()
}

func (f *blobFs) open() error {
	idb := js.Global().Get("indexedDB")
	if idb.IsUndefined() || idb.IsNull() {
		return errors.New("blobs: indexedDB is not available in this context")
	}
	req, err := idbCall(idb, "open", f.name, 1)
	if err != nil {
		return err
	}
	onUpgrade := js.FuncOf(func(js.Value, []js.Value) any {
		req.Get("result").Call("createObjectStore", blobsRecords)
		return nil
	})
	defer onUpgrade.Release()
	req.Set("onupgradeneeded", onUpgrade)
	db, err := idbAwait(req)
	req.Set("onupgradeneeded", js.Null())
	if err != nil {
		return fmt.Errorf("blobs: open %s: %w", f.name, err)
	}
	// Sign-out deletes this database while the page may still hold it open
	// (havenStop closes the route stores, not this): let the delete through
	// rather than leave it blocked. Held for the connection's life.
	db.Set("onversionchange", js.FuncOf(func(js.Value, []js.Value) any {
		db.Call("close")
		return nil
	}))
	f.db = db
	return nil
}

// stored says whether name is a blob kept in IndexedDB rather than in memory.
func (f *blobFs) stored(name string) bool {
	name = filepath.Clean(name)
	return strings.HasPrefix(name, f.prefix) && name != f.prefix && !strings.HasSuffix(name, ".tmp")
}

func (f *blobFs) Create(name string) (afero.File, error) {
	return f.OpenFile(name, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o666)
}

func (f *blobFs) Open(name string) (afero.File, error) {
	return f.OpenFile(name, os.O_RDONLY, 0)
}

// OpenFile reads a stored blob into a memory file. A write is made in memory
// and put into IndexedDB when the file is closed.
func (f *blobFs) OpenFile(name string, flag int, perm os.FileMode) (afero.File, error) {
	if !f.stored(name) {
		if fi, err := f.Fs.Stat(name); err == nil && fi.IsDir() && flag == os.O_RDONLY {
			return f.openDir(name)
		}
		return f.Fs.OpenFile(name, flag, perm)
	}
	key := filepath.Clean(name)
	writing := flag&(os.O_WRONLY|os.O_RDWR|os.O_APPEND|os.O_CREATE|os.O_TRUNC) != 0
	if !writing || flag&os.O_TRUNC == 0 {
		data, ok, err := f.get(key)
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: name, Err: err}
		}
		if !ok && !(writing && flag&os.O_CREATE != 0) {
			return nil, &os.PathError{Op: "open", Path: name, Err: os.ErrNotExist}
		}
		if ok {
			scratch := afero.NewMemMapFs()
			if err := afero.WriteFile(scratch, key, data, 0o644); err != nil {
				return nil, err
			}
			if !writing {
				return scratch.Open(key)
			}
			file, err := scratch.OpenFile(key, flag&^os.O_CREATE, perm)
			if err != nil {
				return nil, err
			}
			return &blobWriter{File: file, fs: f, scratch: scratch, key: key}, nil
		}
	}
	scratch := afero.NewMemMapFs()
	file, err := scratch.OpenFile(key, flag, perm)
	if err != nil {
		return nil, err
	}
	return &blobWriter{File: file, fs: f, scratch: scratch, key: key}, nil
}

// openDir lists a directory from memory and IndexedDB together: afero.Glob
// (openBlobFile's fallback for a blob stored with an extension) reads it.
func (f *blobFs) openDir(name string) (afero.File, error) {
	dir := filepath.Clean(name)
	listing := afero.NewMemMapFs()
	if err := listing.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	names, err := afero.ReadDir(f.Fs, dir)
	if err != nil {
		return nil, err
	}
	for _, fi := range names {
		p := filepath.Join(dir, fi.Name())
		if fi.IsDir() {
			err = listing.MkdirAll(p, 0o755)
		} else {
			err = afero.WriteFile(listing, p, nil, 0o644)
		}
		if err != nil {
			return nil, err
		}
	}
	if !f.db.IsUndefined() {
		keys, err := f.keys()
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: name, Err: err}
		}
		for _, k := range keys {
			if filepath.Dir(k) == dir {
				if err := afero.WriteFile(listing, k, nil, 0o644); err != nil {
					return nil, err
				}
			}
		}
	}
	return listing.Open(dir)
}

func (f *blobFs) Stat(name string) (os.FileInfo, error) {
	if !f.stored(name) {
		return f.Fs.Stat(name)
	}
	file, err := f.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Stat()
}

func (f *blobFs) Remove(name string) error {
	if !f.stored(name) {
		return f.Fs.Remove(name)
	}
	key := filepath.Clean(name)
	ok, err := f.has(key)
	if err == nil && !ok {
		err = os.ErrNotExist
	}
	if err == nil {
		err = f.del(key)
	}
	if err != nil {
		return &os.PathError{Op: "remove", Path: name, Err: err}
	}
	return nil
}

func (f *blobFs) Rename(oldname, newname string) error {
	if !f.stored(oldname) && !f.stored(newname) {
		return f.Fs.Rename(oldname, newname)
	}
	src, err := f.Open(oldname)
	if err != nil {
		return err
	}
	data, err := io.ReadAll(src)
	src.Close()
	if err != nil {
		return err
	}
	if f.stored(newname) {
		err = f.put(filepath.Clean(newname), data)
	} else {
		err = afero.WriteFile(f.Fs, newname, data, 0o644)
	}
	if err != nil {
		return &os.LinkError{Op: "rename", Old: oldname, New: newname, Err: err}
	}
	return f.Remove(oldname)
}

func (f *blobFs) Name() string { return "blobFs" }

// blobWriter is a stored blob being written: in memory until Close puts it.
type blobWriter struct {
	afero.File
	fs      *blobFs
	scratch afero.Fs
	key     string
	closed  bool
}

func (w *blobWriter) Close() error {
	if w.closed {
		return w.File.Close()
	}
	w.closed = true
	if err := w.File.Close(); err != nil {
		return err
	}
	data, err := afero.ReadFile(w.scratch, w.key)
	if err != nil {
		return err
	}
	if err := w.fs.put(w.key, data); err != nil {
		return &os.PathError{Op: "close", Path: w.key, Err: err}
	}
	return nil
}

// ── IndexedDB ──────────────────────────────────────────────────────────

func (f *blobFs) tx(mode string) (js.Value, js.Value, error) {
	if f.db.IsUndefined() {
		return js.Value{}, js.Value{}, errors.New("blobs: database is not open")
	}
	tx, err := idbCall(f.db, "transaction", blobsRecords, mode)
	if err != nil {
		return js.Value{}, js.Value{}, err
	}
	return tx, tx.Call("objectStore", blobsRecords), nil
}

func (f *blobFs) get(key string) ([]byte, bool, error) {
	_, store, err := f.tx("readonly")
	if err != nil {
		return nil, false, err
	}
	req, err := idbCall(store, "get", key)
	if err != nil {
		return nil, false, err
	}
	v, err := idbAwait(req)
	if err != nil || v.IsUndefined() {
		return nil, false, err
	}
	data := make([]byte, v.Get("length").Int())
	js.CopyBytesToGo(data, v)
	return data, true, nil
}

// has counts the record instead of reading it: a video can be large.
func (f *blobFs) has(key string) (bool, error) {
	_, store, err := f.tx("readonly")
	if err != nil {
		return false, err
	}
	req, err := idbCall(store, "count", key)
	if err != nil {
		return false, err
	}
	v, err := idbAwait(req)
	if err != nil {
		return false, err
	}
	return v.Int() > 0, nil
}

// put returns once the transaction has committed, so a blob reported stored
// is on disk.
func (f *blobFs) put(key string, data []byte) error {
	tx, store, err := f.tx("readwrite")
	if err != nil {
		return err
	}
	v := js.Global().Get("Uint8Array").New(len(data))
	js.CopyBytesToJS(v, data)
	if _, err := idbCall(store, "put", v, key); err != nil {
		return err
	}
	return idbAwaitTx(tx)
}

func (f *blobFs) del(key string) error {
	tx, store, err := f.tx("readwrite")
	if err != nil {
		return err
	}
	if _, err := idbCall(store, "delete", key); err != nil {
		return err
	}
	return idbAwaitTx(tx)
}

func (f *blobFs) keys() ([]string, error) {
	_, store, err := f.tx("readonly")
	if err != nil {
		return nil, err
	}
	req, err := idbCall(store, "getAllKeys")
	if err != nil {
		return nil, err
	}
	v, err := idbAwait(req)
	if err != nil {
		return nil, err
	}
	keys := make([]string, v.Length())
	for i := range keys {
		keys[i] = v.Index(i).String()
	}
	sort.Strings(keys)
	return keys, nil
}

// idbAwait, idbAwaitTx and idbCall are idbstore's await, awaitTx and jsCall
// (idbstore/idb.go), which that package does not export. Never call them from
// inside a js.FuncOf callback: that goroutine delivers the result.
func idbAwait(req js.Value) (js.Value, error) {
	type result struct {
		v   js.Value
		err error
	}
	done := make(chan result, 1)
	onSuccess := js.FuncOf(func(js.Value, []js.Value) any {
		done <- result{v: req.Get("result")}
		return nil
	})
	onError := js.FuncOf(func(_ js.Value, args []js.Value) any {
		if len(args) > 0 {
			args[0].Call("preventDefault")
		}
		done <- result{err: idbError(req.Get("error"))}
		return nil
	})
	req.Set("onsuccess", onSuccess)
	req.Set("onerror", onError)
	r := <-done
	req.Set("onsuccess", js.Null())
	req.Set("onerror", js.Null())
	onSuccess.Release()
	onError.Release()
	return r.v, r.err
}

func idbAwaitTx(tx js.Value) error {
	done := make(chan error, 1)
	onComplete := js.FuncOf(func(js.Value, []js.Value) any { done <- nil; return nil })
	onAbort := js.FuncOf(func(js.Value, []js.Value) any {
		err := idbError(tx.Get("error"))
		if err == nil {
			err = errors.New("indexeddb: transaction aborted")
		}
		done <- err
		return nil
	})
	tx.Set("oncomplete", onComplete)
	tx.Set("onabort", onAbort)
	err := <-done
	onComplete.Release()
	onAbort.Release()
	return err
}

func idbError(v js.Value) error {
	if v.IsNull() || v.IsUndefined() {
		return nil
	}
	return fmt.Errorf("indexeddb: %s: %s", v.Get("name").String(), v.Get("message").String())
}

func idbCall(v js.Value, method string, args ...any) (out js.Value, err error) {
	defer func() {
		if r := recover(); r != nil {
			if jerr, ok := r.(js.Error); ok {
				err = fmt.Errorf("indexeddb: %s: %w", method, jerr)
				return
			}
			panic(r)
		}
	}()
	return v.Call(method, args...), nil
}
