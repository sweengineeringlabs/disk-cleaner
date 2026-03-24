# CPU & Performance Profiling Tools Research

## Context

Disk-cleaner operates at the filesystem and process level — cleaning artifacts, analyzing disk usage, monitoring build processes. CPU cycle analysis and register-level profiling is a distinct domain requiring specialized tools that hook into hardware performance counters (PMCs), instruction pipelines, and OS-level tracing infrastructure.

This document catalogs tools for CPU/performance analysis, categorized by platform and use case.

---

## Linux

### perf

- **What**: Linux kernel profiling tool using hardware performance counters
- **Scope**: CPU cycles, cache misses, branch mispredictions, instruction counts, context switches
- **Usage**:
  ```bash
  perf stat cargo build              # summary counters
  perf record cargo build            # sample-based profiling
  perf report                        # analyze recorded profile
  perf stat -e cycles,instructions,cache-misses ./binary
  ```
- **Strengths**: Zero-cost when not active, kernel-level visibility, works with any binary
- **Limitations**: Linux only, needs `perf_event_paranoid` sysctl for non-root use
- **Docs**: https://perf.wiki.kernel.org

### Valgrind (Cachegrind / Callgrind)

- **What**: Instruction-level CPU simulation and cache profiling
- **Scope**: Cache hit/miss rates (L1, L2, LL), branch predictions, call graphs
- **Usage**:
  ```bash
  valgrind --tool=cachegrind ./binary
  valgrind --tool=callgrind ./binary
  kcachegrind callgrind.out.*        # GUI visualization
  ```
- **Strengths**: No hardware counter access needed (simulated), per-line source annotation
- **Limitations**: 10-50x slowdown (simulation overhead), Linux/macOS only
- **Docs**: https://valgrind.org

### strace / ltrace

- **What**: System call and library call tracing
- **Scope**: I/O patterns, syscall frequency, time spent in kernel
- **Usage**:
  ```bash
  strace -c cargo build              # syscall summary
  strace -e trace=file cargo build   # file I/O only
  ```
- **Strengths**: No recompilation needed, shows real I/O behavior
- **Limitations**: Significant overhead, Linux only

---

## Cross-Platform

### Intel VTune Profiler

- **What**: Deep CPU microarchitecture analysis
- **Scope**: Pipeline stalls, port utilization, memory bandwidth, vectorization efficiency, roofline analysis
- **Usage**: GUI-based or CLI (`vtune -collect hotspots ./binary`)
- **Strengths**: Most detailed CPU analysis available, correlates to source lines, supports threading analysis
- **Limitations**: Intel CPUs only (partial AMD support), proprietary (free for open-source)
- **Docs**: https://www.intel.com/content/www/us/en/developer/tools/oneapi/vtune-profiler.html

### AMD uProf

- **What**: AMD's equivalent to VTune
- **Scope**: CPU pipeline analysis, IPC, cache hierarchy, power consumption
- **Strengths**: Best tool for AMD Ryzen/EPYC architectures
- **Docs**: https://www.amd.com/en/developer/uprof.html

### Flamegraph / cargo-flamegraph

- **What**: Visualization of stack-sampled CPU profiles as interactive SVGs
- **Scope**: Where CPU time is spent (function-level), hot paths
- **Usage**:
  ```bash
  cargo install flamegraph
  cargo flamegraph                   # profile the default binary
  cargo flamegraph --bench my_bench  # profile a benchmark
  ```
- **Strengths**: Visual, intuitive, works with Rust/C/C++/Go/Java, integrates with perf/dtrace
- **Limitations**: Sampling-based (may miss short functions), needs debug symbols
- **Docs**: https://github.com/flamegraph-rs/flamegraph

### hyperfine

- **What**: Command-line benchmarking tool
- **Scope**: Execution time comparison, warmup handling, statistical analysis
- **Usage**:
  ```bash
  hyperfine 'cargo build'
  hyperfine --warmup 3 'cargo build' 'cargo build --release'
  hyperfine --export-json results.json 'make build'
  ```
- **Strengths**: Statistical rigor (mean, stddev, outlier detection), warmup support, comparison mode
- **Limitations**: Wall-clock time only (no CPU breakdown)
- **Docs**: https://github.com/sharkdp/hyperfine

### cargo-bench / criterion

- **What**: Rust microbenchmarking frameworks
- **Scope**: Function-level timing, statistical regression detection
- **Usage**:
  ```rust
  // Using criterion
  fn bench_sort(c: &mut Criterion) {
      c.bench_function("sort_1000", |b| b.iter(|| sort_vec(1000)));
  }
  ```
- **Strengths**: Nanosecond precision, HTML reports, CI integration
- **Docs**: https://bheisler.github.io/criterion.rs/book/

---

## Windows

### Windows Performance Analyzer (WPA) / Windows Performance Recorder (WPR)

- **What**: ETW-based system-wide profiling
- **Scope**: CPU sampling, disk I/O, memory allocation, GPU, thread scheduling
- **Usage**:
  ```powershell
  wpr -start CPU                     # start CPU profiling
  cargo build
  wpr -stop build-profile.etl        # stop and save trace
  wpa build-profile.etl              # open in WPA GUI
  ```
- **Strengths**: System-wide visibility (not just your process), built into Windows, correlates CPU + I/O + memory
- **Limitations**: Windows only, large trace files, steep learning curve
- **Docs**: https://learn.microsoft.com/en-us/windows-hardware/test/wpt/

### PerfView

- **What**: .NET and native performance analysis tool by Microsoft
- **Scope**: CPU sampling, GC analysis, memory allocation, ETW events
- **Usage**: GUI tool, can profile any Windows process
- **Strengths**: Excellent for .NET workloads, flamegraph support, free
- **Docs**: https://github.com/microsoft/perfview

### Process Monitor (ProcMon)

- **What**: Real-time file system, registry, and process monitoring
- **Scope**: File I/O operations, registry access, process/thread activity
- **Strengths**: Shows exactly what files a build process reads/writes, filter by process
- **Docs**: https://learn.microsoft.com/en-us/sysinternals/downloads/procmon

---

## Build-Time Analysis

### cargo --timings

- **What**: Built-in Cargo compilation timing report
- **Scope**: Per-crate build time, parallelism utilization, dependency chain bottlenecks
- **Usage**:
  ```bash
  cargo build --timings
  # Generates cargo-timing.html in target/
  ```
- **Strengths**: Zero setup, shows critical path, identifies serial bottlenecks
- **Limitations**: Rust/Cargo only

### sccache

- **What**: Shared compilation cache
- **Scope**: Cache hit rates, compilation time savings, shared across projects
- **Usage**:
  ```bash
  cargo install sccache
  export RUSTC_WRAPPER=sccache
  sccache --show-stats
  ```
- **Strengths**: Dramatic build time reduction for repeated builds, supports Rust/C/C++
- **Docs**: https://github.com/mozilla/sccache

### ccache

- **What**: C/C++ compilation cache
- **Scope**: Compiler output caching, cache hit statistics
- **Strengths**: Mature, widely used, simple setup
- **Docs**: https://ccache.dev

---

## Relevance to disk-cleaner

| Tool | Integration Potential | How |
|------|----------------------|-----|
| hyperfine | High | `analyze -Benchmark` can wrap builds in hyperfine-style timing |
| cargo --timings | High | Parse `cargo-timing.html` for per-crate build bottlenecks |
| sccache stats | Medium | `monitor` can report sccache hit rates if installed |
| perf stat | Medium | `monitor` can invoke `perf stat` for CPU counter summaries on Linux |
| ProcMon data | Low | Too detailed for automated analysis |
| VTune/uProf | Low | Overkill for build process monitoring |

The `analyze -Benchmark` feature focuses on wall-clock build times (hyperfine-style) since that's actionable at the project management level — identifying which projects take longest to build and benefit most from caching or artifact cleanup.
