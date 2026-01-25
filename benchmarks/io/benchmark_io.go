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

type Scenario struct {
	Name        string
	FileSize    int64
	Concurrency int
}

type Result struct {
	Throughput float64 // Gbps
	Duration   time.Duration
	Success    bool
	Workers    int
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

type trackingWriter struct {
	total *int64
}

func (tw trackingWriter) Write(p []byte) (int, error) {
	n := len(p)
	atomic.AddInt64(tw.total, int64(n))
	return n, nil
}

func main() {
	scenarios := []Scenario{
		{"Latency_SmallFile_HighWork", 10 * 1024 * 1024, 50},    // 10MB, 50 workers
		{"Balanced_MedFile_MedWork", 100 * 1024 * 1024, 10},     // 100MB, 10 workers
		{"Throughput_LargeFile_LowWork", 1024 * 1024 * 1024, 2}, // 1GB, 2 workers
		{"Massive_File_Stream", 1024 * 1024 * 1024, 5},          // 1GB, 5 workers (5GB total)
	}

	fmt.Printf("🔥 Running Comprehensive IO Benchmark Suite (Sandbox vs Terminal)\n")
	fmt.Printf("💻 Hardware: %s %s, CPU Cores: %d\n\n", runtime.GOOS, runtime.GOARCH, runtime.NumCPU())

	results := make(map[string]map[string]Result)

	for _, sc := range scenarios {
		fmt.Printf("📦 Scenario: %s (File: %.0fMB, Workers: %d)\n",
			sc.Name, float64(sc.FileSize)/(1024*1024), sc.Concurrency)

		// Create dummy file for this scenario
		filename := "temp_benchmark_file.bin"
		createDummyFile(filename, sc.FileSize)

		results[sc.Name] = make(map[string]Result)

		// Run Workaround (Safe 256KB)
		resWork := runStressTest(sc.Name+"_Sandbox", filename, sc.FileSize, sc.Concurrency, true)
		results[sc.Name]["Sandbox"] = resWork

		// Run Optimized (Native Sendfile)
		resOpt := runStressTest(sc.Name+"_Terminal", filename, sc.FileSize, sc.Concurrency, false)
		results[sc.Name]["Terminal"] = resOpt

		os.Remove(filename)
		fmt.Println("---------------------------------------------------")
	}

	printSummary(scenarios, results)
}

func createDummyFile(filename string, size int64) {
	f, err := os.Create(filename)
	if err != nil {
		panic(err)
	}
	if err := f.Truncate(size); err != nil {
		panic(err)
	}
	f.Close()
}

func runStressTest(name, filename string, fileSize int64, concurrency int, wrap bool) Result {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f, err := os.Open(filename)
		if err != nil {
			fmt.Printf("\n[Server Error] %v\n", err)
			http.Error(w, "Failed to open file", http.StatusInternalServerError)
			return
		}
		defer f.Close()

		defer func() {
			if r := recover(); r != nil {
				fmt.Printf("\n[Server Panic]: %v\n", r)
			}
		}()

		info, err := f.Stat()
		if err != nil {
			http.Error(w, "Failed to stat file", http.StatusInternalServerError)
			return
		}

		if wrap {
			http.ServeContent(w, r, filename, info.ModTime(), SafeFile256K{f})
		} else {
			http.ServeContent(w, r, filename, info.ModTime(), f)
		}
	})

	server := httptest.NewServer(handler)
	defer server.Close()

	var wg sync.WaitGroup
	var completedWorkers int64
	var totalBytesTransferred int64
	start := time.Now()

	fmt.Printf("   running %s... ", name)

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			client := &http.Client{
				Timeout: 120 * time.Second,
			}
			resp, err := client.Get(server.URL)
			if err != nil {
				fmt.Printf("\n[Worker %d Error]: %v\n", id, err)
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusOK {
				fmt.Printf("\n[Worker %d Status]: %d\n", id, resp.StatusCode)
				return
			}

			tw := trackingWriter{total: &totalBytesTransferred}
			_, err = io.Copy(tw, resp.Body)
			if err != nil {
				fmt.Printf("\n[Worker %d Copy Error]: %v\n", id, err)
				return
			}
			atomic.AddInt64(&completedWorkers, 1)
		}(i)
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	var success bool
	select {
	case <-done:
		success = atomic.LoadInt64(&completedWorkers) == int64(concurrency)
	case <-time.After(300 * time.Second):
		fmt.Printf("\n[Timeout] Scenario %s timed out\n", name)
		success = false
	}

	duration := time.Since(start)
	workersDone := int(atomic.LoadInt64(&completedWorkers))

	totalBytes := atomic.LoadInt64(&totalBytesTransferred)
	throughputGbps := (float64(totalBytes*8) / duration.Seconds()) / (1024 * 1024 * 1024)

	fmt.Printf("Done in %v (%.2f Gbps) Success: %v\n", duration.Round(time.Millisecond), throughputGbps, success)

	return Result{
		Throughput: throughputGbps,
		Duration:   duration,
		Success:    success,
		Workers:    workersDone,
	}
}

func printSummary(scenarios []Scenario, results map[string]map[string]Result) {
	fmt.Printf("\n📊 BENCHMARK SUMMARY (256KB vs Native)\n\n")

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "SCENARIO\tFILE\tWORKERS\tTYPE\tTHROUGHPUT\tSPEEDUP\tSTATUS")
	fmt.Fprintln(w, "--------\t----\t-------\t----\t----------\t-------\t------")

	for _, sc := range scenarios {
		work := results[sc.Name]["Sandbox"]
		opt := results[sc.Name]["Terminal"]

		fileStr := fmt.Sprintf("%.0fMB", float64(sc.FileSize)/(1024*1024))
		if sc.FileSize >= 1024*1024*1024 {
			fileStr = fmt.Sprintf("%.1fGB", float64(sc.FileSize)/(1024*1024*1024))
		}

		// Workaround Row
		statusWork := "✅"
		if !work.Success {
			statusWork = fmt.Sprintf("❌ (%d/%d)", work.Workers, sc.Concurrency)
		}
		fmt.Fprintf(w, "%s\t%s\t%d\tSandbox (256KB Buffer)\t%.2f Gbps\t-\t%s\n",
			sc.Name, fileStr, sc.Concurrency, work.Throughput, statusWork)

		// Optimized Row
		statusOpt := "✅"
		if !opt.Success {
			statusOpt = fmt.Sprintf("❌ (%d/%d)", opt.Workers, sc.Concurrency)
		}
		speedup := opt.Throughput / work.Throughput
		fmt.Fprintf(w, " \t \t \tTerminal (Native Sendfile)\t%.2f Gbps\t%.2fx\t%s\n",
			opt.Throughput, speedup, statusOpt)

		fmt.Fprintln(w, "\t\t\t\t\t\t")
	}
	w.Flush()
}
