//go:build js && wasm

package idbstore

import (
	"errors"
	"fmt"
	"syscall/js"
)

// await blocks the calling goroutine until an IDBRequest (or IDBOpenDBRequest)
// settles. It must not be called from inside a js.FuncOf callback: the callback
// goroutine is the one that would deliver the result, so it would deadlock.
//
// The transaction stays active across the wait because the Go wasm runtime
// only hands control back to JavaScript once every goroutine is blocked, so the
// next request is issued while the success event is still being dispatched.
func await(req js.Value) (js.Value, error) {
	type result struct {
		v   js.Value
		err error
	}
	done := make(chan result, 1)
	var onSuccess, onError js.Func
	onSuccess = js.FuncOf(func(this js.Value, args []js.Value) any {
		done <- result{v: req.Get("result")}
		return nil
	})
	onError = js.FuncOf(func(this js.Value, args []js.Value) any {
		if len(args) > 0 {
			args[0].Call("preventDefault") // keep a failed put from aborting the whole transaction
		}
		done <- result{err: domError(req.Get("error"))}
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

// awaitTx blocks until a transaction commits, or returns why it aborted.
func awaitTx(tx js.Value) error {
	done := make(chan error, 1)
	var onComplete, onAbort js.Func
	onComplete = js.FuncOf(func(this js.Value, args []js.Value) any {
		done <- nil
		return nil
	})
	onAbort = js.FuncOf(func(this js.Value, args []js.Value) any {
		err := domError(tx.Get("error"))
		if err == nil {
			err = errors.New("indexeddb: transaction aborted")
		}
		done <- err
		return nil
	})
	tx.Set("oncomplete", onComplete)
	tx.Set("onabort", onAbort)
	tx.Set("onerror", js.Null())
	err := <-done
	onComplete.Release()
	onAbort.Release()
	return err
}

// cursorWalk iterates an IDBCursorWithValue request, calling fn for each
// record until fn returns false or the range is exhausted.
func cursorWalk(req js.Value, fn func(cursor js.Value) bool) error {
	results := make(chan js.Value, 1)
	errs := make(chan error, 1)
	onSuccess := js.FuncOf(func(this js.Value, args []js.Value) any {
		results <- req.Get("result")
		return nil
	})
	onError := js.FuncOf(func(this js.Value, args []js.Value) any {
		errs <- domError(req.Get("error"))
		return nil
	})
	defer func() {
		req.Set("onsuccess", js.Null())
		req.Set("onerror", js.Null())
		onSuccess.Release()
		onError.Release()
	}()
	req.Set("onsuccess", onSuccess)
	req.Set("onerror", onError)
	for {
		select {
		case cursor := <-results:
			if cursor.IsNull() {
				return nil
			}
			if !fn(cursor) {
				return nil
			}
			cursor.Call("continue")
		case err := <-errs:
			return err
		}
	}
}

// DOMError is an IndexedDB failure as reported by the browser.
type DOMError struct{ Name, Message string }

func (e *DOMError) Error() string { return "indexeddb: " + e.Name + ": " + e.Message }

func domError(v js.Value) error {
	if v.IsNull() || v.IsUndefined() {
		return nil
	}
	return &DOMError{Name: v.Get("name").String(), Message: v.Get("message").String()}
}

// jsCall wraps a call that may throw synchronously (bad key range, closed
// database, inactive transaction) and turns the exception into an error.
func jsCall(v js.Value, method string, args ...any) (out js.Value, err error) {
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
