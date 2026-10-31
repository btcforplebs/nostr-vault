//go:build !cshared && !(js && wasm)

package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// The standalone relay closes its databases on SIGTERM/SIGINT before it
// exits. Without this a stop (docker stop, the Linux box's supervisor before
// a vault move) killed it with Badger still open. C-shared hosts stop the
// relay through StopRelayC instead.
func init() {
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
		sig := <-ch
		log.Printf("🛑 %v: closing databases", sig)
		select {
		case <-CloseDBs():
		case <-time.After(15 * time.Second):
			log.Println("⚠️ databases still busy after 15s; exiting anyway")
		}
		os.Exit(0)
	}()
}
