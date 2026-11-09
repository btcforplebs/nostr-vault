//go:build !js
// +build !js

/*
 * SPDX-FileCopyrightText: © Hypermode Inc. <hello@hypermode.com>
 * SPDX-License-Identifier: Apache-2.0
 */

package z

import (
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

// mmap uses the mmap system call to memory-map a file. If writable is true,
// memory protection of the pages is set so that they may be written to as well.
//
// HAVEN: map with unix.MmapPtr, not unix.Mmap. unix.Mmap records every mapping
// in x/sys's global map keyed by a pointer to the mapping's last byte, and the
// raw munmap/mremap below never remove it. On Android the Go heap later grows
// over the freed range and the GC aborts on the stale key ("found bad pointer
// in Go heap"). Nothing registered means nothing goes stale.
// See dgraph-io/ristretto#509 and third_party/ristretto/HAVEN_FORK.md.
func mmap(fd *os.File, writable bool, size int64) ([]byte, error) {
	mtype := unix.PROT_READ
	if writable {
		mtype |= unix.PROT_WRITE
	}
	if size <= 0 {
		return nil, unix.EINVAL
	}
	p, err := unix.MmapPtr(int(fd.Fd()), 0, nil, uintptr(size), mtype, unix.MAP_SHARED)
	if err != nil {
		return nil, err
	}
	return unsafe.Slice((*byte)(p), int(size)), nil
}

// munmap unmaps a previously mapped slice.
//
// unix.Munmap maintains an internal list of mmapped addresses, and only calls munmap
// if the address is present in that list. If we use mremap, this list is not updated.
// To bypass this, we call munmap ourselves.
func munmap(data []byte) error {
	if len(data) == 0 || len(data) != cap(data) {
		return unix.EINVAL
	}
	_, _, errno := unix.Syscall(
		unix.SYS_MUNMAP,
		uintptr(unsafe.Pointer(&data[0])),
		uintptr(len(data)),
		0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}

// madvise uses the madvise system call to give advise about the use of memory
// when using a slice that is memory-mapped to a file. Set the readahead flag to
// false if page references are expected in random order.
func madvise(b []byte, readahead bool) error {
	flags := unix.MADV_NORMAL
	if !readahead {
		flags = unix.MADV_RANDOM
	}
	return unix.Madvise(b, flags)
}

// msync writes any modified data to persistent storage.
func msync(b []byte) error {
	return unix.Msync(b, unix.MS_SYNC)
}
