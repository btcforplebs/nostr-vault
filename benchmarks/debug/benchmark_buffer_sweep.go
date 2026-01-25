package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"sync/atomic"
	"text/tabwriter"
	"time"
)

const (
	TestFile    = "sweep_buffer_test.bin"
	TestSizeMB  = 100 // 100MB per request
	Concurrency = 300 // High concurrency to trigger errors
)

type SweepResult struct {
	BufferSize int
	Throughput float64
	Success    bool
	ErrCount   int
}

// Custom wrapper to use a specific buffer size
type CustomBufferFile struct {
	f          *os.File
	bufferSize int
}

func (c CustomBufferFile) Read(p []byte) (n int, err error) {
	return c.f.Read(p)
}

func (c CustomBufferFile) Seek(offset int64, whence int) (int64, error) {
	return c.f.Seek(offset, whence)
}

func (c CustomBufferFile) WriteTo(dst io.Writer) (int64, error) {
	buf := make([]byte, c.bufferSize)
	return io.CopyBuffer(dst, c.f, buf)
}

func main() {
	// Create a test file
	f, _ := os.Create(TestFile)
	f.Truncate(TestSizeMB * 1024 * 1024)
	f.Close()
	defer os.Remove(TestFile)

	bufferSizes := []int{
		4 * 1024,    // 4KB
		32 * 1024,   // 32KB (Default)
		64 * 1024,   // 64KB
		128 * 1024,  // 128KB
		256 * 1024,  // 256KB
		512 * 1024,  // 512KB
		1024 * 1024, // 1MB
	}

	fmt.Printf("🧹 Starting Buffer Size Sweep (Concurrency: %d, File: %dMB)\n", Concurrency, TestSizeMB)

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "BUFFER SIZE\tTHROUGHPUT\tERRORS\tSTATUS")
	fmt.Fprintln(w, "-----------\t----------\t------\t------")

	for _, bs := range bufferSizes {
		res := runTest(bs)
		status := "✅"
		if !res.Success {
			status = "❌"
		}
		fmt.Fprintf(w, "%d KB\t%.2f Gbps\t%d\t%s\n", bs/1024, res.Throughput, res.ErrCount, status)
	}
	w.Flush()
}

func runTest(bufferSize int) SweepResult {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, err := os.Open(TestFile)
		if err != nil {
			return
		}
		defer f.Close()
		info, _ := f.Stat()

		// Use the custom buffer wrapper
		http.ServeContent(w, r, TestFile, info.ModTime(), CustomBufferFile{f, bufferSize})
	})

	server := httptest.NewServer(handler)
	defer server.Close()

	var wg sync.WaitGroup
	var errCount int64
	var totalBytes int64

	fmt.Printf("   Testing %d KB buffer... ", bufferSize/1024)

	start := time.Now()
	for i := 0; i < Concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			client := &http.Client{Timeout: 10 * time.Second}
			resp, err := client.Get(server.URL)
			if err != nil {
				atomic.AddInt64(&errCount, 1)
				return
			}
			defer resp.Body.Close()

			n, err := io.Copy(io.Discard, resp.Body)
			atomic.AddInt64(&totalBytes, n)
			if err != nil || resp.StatusCode != 200 {
				atomic.AddInt64(&errCount, 1)
			}
		}()
	}

	wg.Wait()
	duration := time.Since(start)

	fmt.Printf("Done!\n")

	throughput := (float64(atomic.LoadInt64(&totalBytes)) * 8) / (duration.Seconds() * 1024 * 1024 * 1024)

	return SweepResult{
		BufferSize: bufferSize,
		Throughput: throughput,
		Success:    atomic.LoadInt64(&errCount) == 0,
		ErrCount:   int(atomic.LoadInt64(&errCount)),
	}
}
