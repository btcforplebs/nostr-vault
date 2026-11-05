//go:build !(js && wasm)

package main

import "syscall"

// freeBytes is the space free for this user on the filesystem holding path.
func freeBytes(path string) (uint64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, false
	}
	return uint64(st.Bavail) * uint64(st.Bsize), true
}
