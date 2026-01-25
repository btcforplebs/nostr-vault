package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"time"
)

// Optimized Wrapper (Our 256KB Strategy)
type SafeFile256K struct {
	f *os.File
}

func (s SafeFile256K) Read(p []byte) (n int, err error) {
	return s.f.Read(p)
}

func (s SafeFile256K) Seek(offset int64, whence int) (int64, error) {
	return s.f.Seek(offset, whence)
}

func (s SafeFile256K) WriteTo(dst io.Writer) (int64, error) {
	// 256KB buffer
	buf := make([]byte, 256*1024)
	return io.CopyBuffer(dst, s.f, buf)
}

func main() {
	fmt.Printf("🏁 Final Showdown: Native Sendfile vs 256KB User-Space\n")

	filename := "final_showdown.bin"
	f, _ := os.Create(filename)
	f.Truncate(1024 * 1024 * 1024) // 1GB File
	f.Close()
	defer os.Remove(filename)

	// 1. Native Sendfile (The "Unstable Fast" Path)
	runTest("Native Sendfile", filename, false)

	// 2. Safe 256KB Buffer (The "Stable Optimized" Path)
	runTest("Safe 256KB Buffer", filename, true)
}

func runTest(name, filename string, useWrapper bool) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, _ := os.Open(filename)
		defer f.Close()
		info, _ := f.Stat()

		if useWrapper {
			http.ServeContent(w, r, filename, info.ModTime(), SafeFile256K{f})
		} else {
			// Plain os.File triggers sendfile
			http.ServeContent(w, r, filename, info.ModTime(), f)
		}
	})

	server := httptest.NewServer(handler)
	defer server.Close()

	start := time.Now()
	resp, err := http.Get(server.URL)
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()

	bytes, _ := io.Copy(io.Discard, resp.Body)
	duration := time.Since(start)

	throughput := (float64(bytes) * 8) / (duration.Seconds() * 1024 * 1024 * 1024)

	fmt.Printf("[%s] Throughput: %.2f Gbps\n", name, throughput)
}
