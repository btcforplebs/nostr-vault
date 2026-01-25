package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// SafeFile256K is the wrapper we implemented in load_blob_darwin.go
type SafeFile256K struct {
	*os.File
}

func (s SafeFile256K) Read(p []byte) (n int, err error) {
	return s.File.Read(p)
}

func (s SafeFile256K) Seek(offset int64, whence int) (int64, error) {
	return s.File.Seek(offset, whence)
}

func (s SafeFile256K) WriteTo(dst io.Writer) (int64, error) {
	buf := make([]byte, 256*1024)
	return io.CopyBuffer(dst, s.File, buf)
}

func TestBufferReliability(t *testing.T) {
	const (
		filename    = "reliability_test.bin"
		fileSize    = 10 * 1024 * 1024 // 10MB
		concurrency = 100              // Use a more realistic high load for a test
	)

	// Setup
	f, err := os.Create(filename)
	if err != nil {
		t.Fatal(err)
	}
	f.Truncate(fileSize)
	f.Close()
	defer os.Remove(filename)

	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		file, err := os.Open(filename)
		if err != nil {
			return
		}
		defer file.Close()
		info, _ := file.Stat()

		// Use the 256KB buffer wrapper
		http.ServeContent(w, r, filename, info.ModTime(), SafeFile256K{file})
	})

	server := httptest.NewServer(handler)
	defer server.Close()

	var wg sync.WaitGroup
	var errCount int64
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req, _ := http.NewRequestWithContext(ctx, "GET", server.URL, nil)
			client := &http.Client{}
			resp, err := client.Do(req)
			if err != nil {
				atomic.AddInt64(&errCount, 1)
				return
			}
			defer resp.Body.Close()

			_, err = io.Copy(io.Discard, resp.Body)
			if err != nil || resp.StatusCode != http.StatusOK {
				atomic.AddInt64(&errCount, 1)
			}
		}()
	}

	wg.Wait()

	if errCount > 0 {
		t.Errorf("Reliability test failed with %d errors at concurrency %d", errCount, concurrency)
	}
}
