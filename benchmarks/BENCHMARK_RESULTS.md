# Haven Benchmark Results
Running at: Sun Jan 25 07:56:01 EST 2026

## 1. Buffer Benchmark
```
🧪 Testing User-Space Buffer Optimization (256KB vs 32KB)
[Standard (32KB)] Throughput: 19.77 Gbps
[Optimized (256KB)] Throughput: 24.66 Gbps
```

## 2. Concurrency Sweep
```
🌊 Starting Concurrency Sweep (100MB file)
💻 Hardware: darwin arm64, Cores: 14

   [1 workers] Running... Done!
   [1 workers] Running... Done!
   [5 workers] Running... Done!
   [5 workers] Running... Done!
   [10 workers] Running... Done!
   [10 workers] Running... Done!
   [25 workers] Running... Done!
   [25 workers] Running... Done!
   [50 workers] Running... Done!
   [50 workers] Running... Done!
   [75 workers] Running... Done!
   [75 workers] Running... Done!
   [100 workers] Running... Done!
   [100 workers] Running... Done!
   [200 workers] Running... Done!
   [200 workers] Running... Done!
   [500 workers] Running... Done!
   [500 workers] Running... Done!
WORKERS   TYPE                         THROUGHPUT   STATUS
-------   ----                         ----------   ------
1         Sandbox (256KB Buffer)       23.21 Gbps   ✅
1         Terminal (Native Sendfile)   34.56 Gbps   ✅
                                                    
5         Sandbox (256KB Buffer)       34.87 Gbps   ✅
5         Terminal (Native Sendfile)   43.92 Gbps   ✅
                                                    
10        Sandbox (256KB Buffer)       48.41 Gbps   ✅
10        Terminal (Native Sendfile)   40.38 Gbps   ✅
                                                    
25        Sandbox (256KB Buffer)       50.02 Gbps   ✅
25        Terminal (Native Sendfile)   37.38 Gbps   ✅
                                                    
50        Sandbox (256KB Buffer)       44.91 Gbps   ✅
50        Terminal (Native Sendfile)   28.96 Gbps   ✅
                                                    
75        Sandbox (256KB Buffer)       10.54 Gbps   ✅
75        Terminal (Native Sendfile)   26.81 Gbps   ✅
                                                    
100       Sandbox (256KB Buffer)       23.28 Gbps   ✅
100       Terminal (Native Sendfile)   22.13 Gbps   ✅
                                                    
200       Sandbox (256KB Buffer)       13.29 Gbps   ❌ (45 errs)
200       Terminal (Native Sendfile)   12.68 Gbps   ❌ (40 errs)
                                                    
500       Sandbox (256KB Buffer)       14.17 Gbps   ❌ (462 errs)
500       Terminal (Native Sendfile)   19.19 Gbps   ❌ (279 errs)
                                                    
```

## 3. IO Benchmark
```
🔥 Running Comprehensive IO Benchmark Suite (Sandbox vs Terminal)
💻 Hardware: darwin arm64, CPU Cores: 14

📦 Scenario: Latency_SmallFile_HighWork (File: 10MB, Workers: 50)
   running Latency_SmallFile_HighWork_Sandbox... Done in 164ms (23.85 Gbps) Success: true
   running Latency_SmallFile_HighWork_Terminal... Done in 140ms (27.80 Gbps) Success: true
---------------------------------------------------
📦 Scenario: Balanced_MedFile_MedWork (File: 100MB, Workers: 10)
   running Balanced_MedFile_MedWork_Sandbox... Done in 295ms (26.48 Gbps) Success: true
   running Balanced_MedFile_MedWork_Terminal... Done in 199ms (39.32 Gbps) Success: true
---------------------------------------------------
📦 Scenario: Throughput_LargeFile_LowWork (File: 1024MB, Workers: 2)
   running Throughput_LargeFile_LowWork_Sandbox... Done in 512ms (31.25 Gbps) Success: true
   running Throughput_LargeFile_LowWork_Terminal... Done in 361ms (44.29 Gbps) Success: true
---------------------------------------------------
📦 Scenario: Massive_File_Stream (File: 1024MB, Workers: 5)
   running Massive_File_Stream_Sandbox... Done in 1.304s (30.68 Gbps) Success: true
   running Massive_File_Stream_Terminal... Done in 805ms (49.70 Gbps) Success: true
---------------------------------------------------

📊 BENCHMARK SUMMARY (256KB vs Native)

SCENARIO                       FILE    WORKERS   TYPE                         THROUGHPUT   SPEEDUP   STATUS
--------                       ----    -------   ----                         ----------   -------   ------
Latency_SmallFile_HighWork     10MB    50        Sandbox (256KB Buffer)       23.85 Gbps   -         ✅
                                                 Terminal (Native Sendfile)   27.80 Gbps   1.17x     ✅
                                                                                                     
Balanced_MedFile_MedWork       100MB   10        Sandbox (256KB Buffer)       26.48 Gbps   -         ✅
                                                 Terminal (Native Sendfile)   39.32 Gbps   1.49x     ✅
                                                                                                     
Throughput_LargeFile_LowWork   1.0GB   2         Sandbox (256KB Buffer)       31.25 Gbps   -         ✅
                                                 Terminal (Native Sendfile)   44.29 Gbps   1.42x     ✅
                                                                                                     
Massive_File_Stream            1.0GB   5         Sandbox (256KB Buffer)       30.68 Gbps   -         ✅
                                                 Terminal (Native Sendfile)   49.70 Gbps   1.62x     ✅
                                                                                                     
```

## 4. Verify 256K Strategy
```
🔬 Verifying 256KB Optimization
[Standard (32KB)] Throughput: 25.91 Gbps
[Optimized (256KB)] Throughput: 26.99 Gbps
```

## 5. Final Comparison
```
🏁 Final Showdown: Native Sendfile vs 256KB User-Space
[Native Sendfile] Throughput: 47.28 Gbps
[Safe 256KB Buffer] Throughput: 28.51 Gbps
```

## 6. Buffer Sweep (Debug)
```
🧹 Starting Buffer Size Sweep (Concurrency: 300, File: 100MB)
   Testing 4 KB buffer... Done!
   Testing 32 KB buffer... Done!
   Testing 64 KB buffer... Done!
   Testing 128 KB buffer... Done!
   Testing 256 KB buffer... Done!
   Testing 512 KB buffer... Done!
   Testing 1024 KB buffer... Done!
BUFFER SIZE   THROUGHPUT   ERRORS   STATUS
-----------   ----------   ------   ------
4 KB          13.24 Gbps   234      ❌
32 KB         14.10 Gbps   220      ❌
64 KB         16.59 Gbps   191      ❌
128 KB        17.01 Gbps   168      ❌
256 KB        15.48 Gbps   187      ❌
512 KB        18.21 Gbps   154      ❌
1024 KB       17.39 Gbps   192      ❌
```

## 7. Reliability Test (Go Test)
```
=== RUN   TestBufferReliability
--- PASS: TestBufferReliability (0.78s)
PASS
ok  	command-line-arguments	1.403s
```

