package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"text/tabwriter"
	"time"
)

const (
	TestFile   = "sweep_test.bin"
	TestSizeMB = 100
)

type StepResult struct {
	Concurrency int
	Type        string
	Throughput  float64
	Success     bool
	ErrCount    int
}

func main() {
	// Create a 100MB test file
	f, _ := os.Create(TestFile)
	f.Truncate(TestSizeMB * 1024 * 1024)
	f.Close()
	defer os.Remove(TestFile)

	steps := []int{1, 5, 10, 25, 50, 75, 100, 200, 500}

	fmt.Printf("🌊 Starting Concurrency Sweep (%dMB file)\n", TestSizeMB)
	fmt.Printf("💻 Hardware: %s %s, Cores: %d\n\n", runtime.GOOS, runtime.GOARCH, runtime.NumCPU())

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "WORKERS\tTYPE\tTHROUGHPUT\tSTATUS")
	fmt.Fprintln(w, "-------\t----\t----------\t------")

	for _, c := range steps {
		// Test Workaround
		resW := runTest(c, true)
		fmt.Fprintf(w, "%d\tSandbox (256KB Buffer)\t%.2f Gbps\t%s\n", c, resW.Throughput, statusIcon(resW))

		// Test Optimized
		resO := runTest(c, false)
		fmt.Fprintf(w, "%d\tTerminal (Native Sendfile)\t%.2f Gbps\t%s\n", c, resO.Throughput, statusIcon(resO))

		fmt.Fprintln(w, "\t\t\t")
	}
	w.Flush()
}

func statusIcon(r StepResult) string {
	if r.Success {
		return "✅"
	}
	return fmt.Sprintf("❌ (%d errs)", r.ErrCount)
}

// Optimization: 256KB user-space buffer
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
	buf := make([]byte, 256*1024)
	return io.CopyBuffer(dst, s.f, buf)
}

func runTest(concurrency int, wrap bool) StepResult {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, err := os.Open(TestFile)
		if err != nil {
			return
		}
		defer f.Close()
		info, _ := f.Stat()
		if wrap {
			// Use the optimized 256KB buffer wrapper
			http.ServeContent(w, r, TestFile, info.ModTime(), SafeFile256K{f})
		} else {
			// Use standard file (triggers sendfile)
			http.ServeContent(w, r, TestFile, info.ModTime(), f)
		}
	})

	server := httptest.NewServer(handler)
	defer server.Close()

	var wg sync.WaitGroup
	var errCount int64
	var totalBytes int64

	fmt.Printf("   [%d workers] Running... ", concurrency)

	start := time.Now()
	for i := 0; i < concurrency; i++ {
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

			// Use a limited reader to ensure we don't hang forever if the OS stops sending
			n, err := io.Copy(io.Discard, resp.Body)
			atomic.AddInt64(&totalBytes, n)
			if err != nil || resp.StatusCode != 200 {
				atomic.AddInt64(&errCount, 1)
			}
		}()
	}

	// Create a channel to signal completion
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	var success bool
	select {
	case <-done:
		success = atomic.LoadInt64(&errCount) == 0
		fmt.Printf("Done!\n")
	case <-time.After(45 * time.Second): // Safety timeout for the entire batch
		success = false
		fmt.Printf("TIMED OUT!\n")
	}

	duration := time.Since(start)
	throughput := (float64(atomic.LoadInt64(&totalBytes)) * 8) / (duration.Seconds() * 1024 * 1024 * 1024)

	return StepResult{
		Concurrency: concurrency,
		Type:        ifElse(wrap, "Sandbox (256KB Buffer)", "Terminal (Native Sendfile)"),
		Throughput:  throughput,
		Success:     success,
		ErrCount:    int(atomic.LoadInt64(&errCount)),
	}
}

func ifElse(cond bool, a, b string) string {
	if cond {
		return a
	}
	return b
}
