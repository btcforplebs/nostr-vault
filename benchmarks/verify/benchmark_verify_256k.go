package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"time"
)

// Optimized Wrapper (Simulation of what we just implemented)
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
	fmt.Printf("🔬 Verifying 256KB Optimization\n")

	filename := "verify_opt.bin"
	f, _ := os.Create(filename)
	f.Truncate(500 * 1024 * 1024) // 500MB
	f.Close()
	defer os.Remove(filename)

	runVerification("Standard (32KB)", filename, false)
	runVerification("Optimized (256KB)", filename, true)
}

func runVerification(name, filename string, optimized bool) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, _ := os.Open(filename)
		defer f.Close()
		info, _ := f.Stat()

		if optimized {
			http.ServeContent(w, r, filename, info.ModTime(), SafeFile256K{f})
		} else {
			http.ServeContent(w, r, filename, info.ModTime(), struct{ io.ReadSeeker }{f})
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
	io.Copy(io.Discard, resp.Body)

	duration := time.Since(start)
	throughput := (500.0 * 8) / duration.Seconds() / 1024.0 // Gbps approx logic

	fmt.Printf("[%s] Throughput: %.2f Gbps\n", name, throughput)
}
