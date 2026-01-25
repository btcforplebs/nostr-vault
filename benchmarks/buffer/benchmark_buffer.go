package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"time"
)

const (
	TestFile   = "buffer_opt_test.bin"
	TestSize   = 500 * 1024 * 1024 // 500MB
	BufferSize = 256 * 1024        // 256KB Optimistic Buffer
)

type OptimizedWrapper struct {
	f *os.File
}

func (w OptimizedWrapper) Read(p []byte) (n int, err error) {
	return w.f.Read(p)
}

func (w OptimizedWrapper) Seek(offset int64, whence int) (int64, error) {
	return w.f.Seek(offset, whence)
}

// WriteTo implements io.WriterTo to hijack the copy loop and use a larger buffer
func (w OptimizedWrapper) WriteTo(dst io.Writer) (int64, error) {
	// Standard io.Copy uses 32KB. We use 256KB.
	buf := make([]byte, BufferSize)
	return io.CopyBuffer(dst, w.f, buf)
}

func main() {
	fmt.Printf("🧪 Testing User-Space Buffer Optimization (256KB vs 32KB)\n")

	// Create dummy file
	f, _ := os.Create(TestFile)
	f.Truncate(TestSize)
	f.Close()
	defer os.Remove(TestFile)

	runTest("Standard (32KB)", false)
	runTest("Optimized (256KB)", true)
}

func runTest(name string, useOpt bool) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, _ := os.Open(TestFile)
		defer f.Close()
		info, _ := f.Stat()

		if useOpt {
			// Uses WriteTo with 1MB buffer
			http.ServeContent(w, r, TestFile, info.ModTime(), OptimizedWrapper{f})
		} else {
			// Standard struct wrapper (uses default io.Copy 32KB)
			http.ServeContent(w, r, TestFile, info.ModTime(), struct{ io.ReadSeeker }{f})
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
