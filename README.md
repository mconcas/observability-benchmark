# Observability Stack Benchmark

Benchmarking and validation suite for Fluent-Bit → OpenSearch log ingestion pipelines, powered by a high-performance C++ syslog injector.

## Overview

End-to-end testing of log pipelines with configurable load generation (100–50,000 msg/s), data integrity validation, and real-time monitoring. Supports multiple backends: OpenSearch, HTTP, file, stdout, and null.

> **Data integrity first** — Fluent-Bit metrics can report 100% success while data is silently lost. This suite validates every message actually reached OpenSearch.

## Components

### Syslog Injector (`syslog_injector.cpp`)

High-performance C++ tool that sends templated syslog messages to Fluent-Bit via Unix socket with precise rate control, batching, and real-time statistics. Supports placeholders: `{timestamp}`, `{hostname}`, `{pid}`, `{counter}`.

### Configurations

**Injector profiles** (`configs/injector/profiles/`):

| Profile | Rate | Duration | Total Messages | Use Case |
|---------|------|----------|----------------|----------|
| `low_rate` | 100 msg/s | 30s | 3,000 | Baseline validation |
| `medium_rate` | 1,000 msg/s | 60s | 60,000 | Typical production load |
| `high_rate` | 10,000 msg/s | 60s | 600,000 | Peak load testing |
| `stress_test` | 50,000 msg/s | 120s | 6,000,000 | Stress testing / limits |

**Fluent-Bit configs** (`configs/fluent-bit/`):

| Config | Purpose |
|--------|---------|
| `fluent-bit-opensearch-optimized.conf` | **Recommended** — high-throughput with auth |
| `fluent-bit-opensearch-noauth-optimized.conf` | **Recommended** — high-throughput, no auth |
| `fluent-bit-opensearch.conf` | OpenSearch with authentication |
| `fluent-bit-opensearch-noauth.conf` | OpenSearch without authentication |
| `fluent-bit-null.conf` | Discard output (baseline perf testing) |
| `fluent-bit-file.conf` | Write to file (I/O performance) |
| `fluent-bit-http.conf` | Generic HTTP endpoint |
| `fluent-bit-stdout.conf` | Console output (debugging) |
| `parsers.conf` | Syslog parsers (RFC3164 / RFC5424) |

> **For throughput >10k msg/s**, always use the optimized configs. They include filesystem buffering, high retry limits, increased buffer sizes, and tuned flush intervals.

### Scripts

| Script | Purpose |
|--------|---------|
| `run_opensearch_benchmark.sh` | **Main script** — run test with OpenSearch validation |
| `validate_opensearch.py` | Validate message integrity, detect loss/gaps/duplicates |
| `check_metrics.sh` | Real-time pipeline health monitoring |
| `analyze_fluentbit_logs.sh` | Post-test log analysis |
| `build.sh` | Compile the C++ injector |
| `run_benchmark.sh` | Generic benchmark runner (any output) |
| `run_all_benchmarks.sh` | Run all predefined profiles |
| `run_matrix_tests.sh` | Matrix testing (3 outputs × 4 profiles) |
| `compare_results.py` | Multi-run performance comparison |

## Quick Start

### Prerequisites

- C++ compiler with C++17 support (g++ or clang++)
- Fluent-Bit installed and in PATH
- Python 3 with standard library
- Linux with Unix socket support
- OpenSearch cluster (for data integrity validation)
- Optional: CMake 3.10+, jq

### Build

```bash
./build.sh
# or: make
# or: mkdir build && cd build && cmake .. && make
```

### Run an OpenSearch Benchmark

```bash
chmod +x *.sh

# Configure OpenSearch connection
export OPENSEARCH_HOST="your-opensearch-host.example.com"
export OPENSEARCH_USER="admin"              # omit for no-auth clusters
export OPENSEARCH_PASSWORD="your-password"  # omit for no-auth clusters

# Medium rate test (1,000 msg/s × 60s = 60,000 messages)
./run_opensearch_benchmark.sh --profile medium_rate --optimized --cleanup

# High throughput test (10,000 msg/s × 60s = 600,000 messages)
./run_opensearch_benchmark.sh --profile high_rate --optimized --cleanup

# Without SSL
./run_opensearch_benchmark.sh --profile medium_rate --no-ssl --optimized --cleanup
```

This starts Fluent-Bit, injects messages at the specified rate, waits for buffers to flush, validates all messages in OpenSearch, and reports integrity results.

### Run Without OpenSearch

```bash
# Baseline performance (null output)
./run_benchmark.sh -p high_rate -f configs/fluent-bit/fluent-bit-null.conf -m

# File output
./run_benchmark.sh -p medium_rate -f configs/fluent-bit/fluent-bit-file.conf -m

# All profiles sequentially
./run_all_benchmarks.sh

# Matrix test (3 outputs × 4 profiles = 12 tests)
./run_matrix_tests.sh
```

## Configuration

### Injector Config Format

```ini
socket_path = /tmp/fluentbit.sock
message_format = <134>1 {timestamp} {hostname} test-app {pid} - - Test message #{counter}
target_rate = 1000
duration = 60
batch_size = 100
verbose = false
```

**Placeholders**: `{timestamp}` (RFC3339), `{hostname}`, `{pid}`, `{counter}` (sequential).

### Optimized Fluent-Bit Settings (High Throughput)

The optimized configs include:

- **Filesystem Buffering** — persistent storage prevents data loss during backpressure
- **Retry Configuration** — `Retry_Limit 10000` (vs. default 3)
- **Buffer Sizes** — `Buffer_Size 2M` for large OpenSearch responses
- **Flush Intervals** — `Flush 2s` to stay under circuit breaker limits
- **Input Buffers** — `Buffer_Size 256KB`, `Buffer_Max_Size 1MB`

### OpenSearch Cluster Tuning

- **Index Refresh**: Set to 5–10s for ingestion workloads (default 1s causes backpressure)
- **Bulk Thread Pool**: Increase if seeing `queue_capacity_exception`
- **Circuit Breaker**: Monitor for HTTP 429 errors (~972MB default)
- **Shard Count**: More shards = better write parallelism
- **Replica Count**: Set to 0 during benchmarks for maximum throughput

> **Note**: `stress_test` at 50k msg/s will exceed most OpenSearch clusters (~1k-5k msg/s typical). Use it to find breaking points.

## Monitoring

### Real-time Metrics

```bash
# In a separate terminal during a test
./check_metrics.sh
```

Shows input/output rates, lag, retry rates (backpressure indicator), and storage buffering status.

Watch for:
- **LAG growing** → backpressure
- **RETRY_RATE > 0** → OpenSearch rejections
- **OUTPUT_RATE << INPUT_RATE** → pipeline bottleneck

### Injector Output

```
Elapsed: 10.5s | Messages: 10500 | Rate: 1000.00 msg/s | Throughput: 125.50 KB/s | Errors: 0
```

### Fluent-Bit Metrics API

```bash
curl http://localhost:2020/api/v1/metrics
```

### Post-Test Log Analysis

```bash
./analyze_fluentbit_logs.sh results/fluentbit_20260212_190209.log
```

## Usage Examples

### Production Cluster (with Auth)

```bash
export OPENSEARCH_HOST="your-cluster.example.com"
export OPENSEARCH_USER="admin"
export OPENSEARCH_PASSWORD="your-secure-password"

./run_opensearch_benchmark.sh --profile medium_rate --optimized --cleanup
./run_opensearch_benchmark.sh --profile high_rate --optimized --cleanup
```

### Development Cluster (No Auth)

```bash
export OPENSEARCH_HOST="opensearch-dev.local"
./run_opensearch_benchmark.sh --profile medium_rate --no-ssl --optimized --cleanup
```

### Capacity Planning

```bash
export OPENSEARCH_HOST="your-cluster.example.com"

# Progressively increase load to find limits
./run_opensearch_benchmark.sh --profile low_rate --optimized
./run_opensearch_benchmark.sh --profile medium_rate --optimized
./run_opensearch_benchmark.sh --profile high_rate --optimized
./run_opensearch_benchmark.sh --profile stress_test --optimized
```

### Manual Validation (Existing Index)

```bash
python3 validate_opensearch.py \
  --host opensearch.example.com \
  --user admin \
  --password your-password \
  --index fluentbit-bench-high_rate-20260212-120000 \
  --expected-count 600000
```

### Custom Message Format

Edit `configs/injector/default.conf`:
```ini
message_format = <134>1 {timestamp} {hostname} my-app {pid} - [custom@12345 key="value"] Custom message #{counter}
duration = 30
```

## Performance Tips

**Maximum throughput**: Use `fluent-bit-null.conf`, increase `batch_size` (500–1000), set Fluent-Bit `Log_Level error`.

**Realistic testing**: Use HTTP or file output, moderate batch sizes (100–200), monitor via `check_metrics.sh`.

## References

- [Fluent-Bit Documentation](https://docs.fluentbit.io/)
- [Syslog Input Plugin](https://docs.fluentbit.io/manual/data-pipeline/inputs/syslog)
- [RFC5424 — Syslog Protocol](https://tools.ietf.org/html/rfc5424)
- [RFC3164 — BSD Syslog Protocol](https://tools.ietf.org/html/rfc3164)