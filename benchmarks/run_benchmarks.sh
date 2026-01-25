#!/bin/bash

# Haven Benchmark Runner
# Runs all benchmark suites sequentially and generates a Markdown report

set -e

REPORT_FILE="benchmarks/BENCHMARK_RESULTS.md"

echo "# Haven Benchmark Results" > "$REPORT_FILE"
echo "Running at: $(date)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

echo "🚀 Starting Haven Benchmarks..."
echo "=============================="

run_benchmark() {
    title="$1"
    cmd="$2"
    
    echo ""
    echo "📦 Running $title..."
    
    echo "## $title" >> "$REPORT_FILE"
    echo "\`\`\`" >> "$REPORT_FILE"
    
    # Run command, capture output, tee to console and append to report
    $cmd | tee -a "$REPORT_FILE"
    
    echo "\`\`\`" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

# 1. Buffer Benchmark
run_benchmark "1. Buffer Benchmark" "go run benchmarks/buffer/benchmark_buffer.go"

# 2. Concurrency Sweep
run_benchmark "2. Concurrency Sweep" "go run benchmarks/concurrency/concurrency_sweep.go"

# 3. IO Benchmark
run_benchmark "3. IO Benchmark" "go run benchmarks/io/benchmark_io.go"

# 4. Verify 256K Strategy
run_benchmark "4. Verify 256K Strategy" "go run benchmarks/verify/benchmark_verify_256k.go"

# 5. Final Comparison
run_benchmark "5. Final Comparison" "go run benchmarks/final/benchmark_final_comparison.go"

# 6. Buffer Sweep (Debug)
run_benchmark "6. Buffer Sweep (Debug)" "go run benchmarks/debug/benchmark_buffer_sweep.go"

# 7. Reliability Test (Go Test)
run_benchmark "7. Reliability Test (Go Test)" "go test -v benchmarks/debug/buffer_reliability_test.go"

echo ""
echo "=============================="
echo "✨ All benchmarks completed successfully!"
echo "📄 Report generated at: $REPORT_FILE"

