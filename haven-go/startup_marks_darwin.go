//go:build darwin

package main

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
)

func osProcessStart() (time.Time, bool) {
	k, err := unix.SysctlKinfoProc("kern.proc.pid", os.Getpid())
	if err != nil {
		return time.Time{}, false
	}
	t := k.Proc.P_starttime
	return time.Unix(int64(t.Sec), int64(t.Usec)*1000), true
}
