# Observability Stack Benchmark

A comprehensive benchmarking and validation suite for evaluating the performance and reliability of Fluent-Bit → OpenSearch observability pipelines using a high-performance C++ message injector.

## Overview

This benchmark suite enables end-to-end testing of log ingestion pipelines with a focus on the **Fluent-Bit + OpenSearch stack**. It provides:

- **Load Generation**: Configurable syslog message injection at precise rates (100 to 50,000 msg/s)
- **Performance Measurement**: Fluent-Bit throughput, latency, and resource utilization metrics
- **Data Integrity Validation**: Comprehensive OpenSearch validation detecting message loss, gaps, and duplicates
- **Capacity Planning**: Pre-configured test profiles from baseline to stress testing
- **Pipeline Optimization**: Identifies bottlenecks, backpressure, and configuration issues
- **Multi-Output Support**: Test various backends (OpenSearch, HTTP, file, stdout, null)

### Key Features

- ✅ **Data Integrity First**: Validates every message reached OpenSearch correctly
- ✅ **Production-Ready**: Optimized configurations for high-throughput scenarios
- ✅ **Real-time Monitoring**: Live metrics showing pipeline health and backpressure
- ✅ **Comprehensive Documentation**: Troubleshooting guides and optimization recommendations
- ⚠️ **Metrics vs Reality**: Tools to detect silent data loss despite "perfect" metrics

## Components

### 1. Syslog Injector (`syslog_injector.cpp`)
A high-performance C++ tool that:
- Reads message format templates from configuration files
- Sends messages to Fluent-Bit via Unix socket
- Controls message rate precisely using batching and timing
- Provides real-time statistics (messages/sec, throughput, errors)
- Supports placeholders: `{timestamp}`, `{hostname}`, `{pid}`, `{counter}`

### 2. Configuration Files
- `injector_config.conf` - Default injector configuration
- `profiles/*.conf` - Pre-configured test profiles:
  - `low_rate.conf` - 100 msg/s for 30 seconds
  - `medium_rate.conf` - 1,000 msg/s for 60 seconds
  - `high_rate.conf` - 10,000 msg/s for 60 seconds
  - `stress_test.conf` - 50,000 msg/s for 120 seconds

### 3. Fluent-Bit Configurations

#### OpenSearch Outputs (Primary Use Case)
- `fluent-bit-opensearch.conf` - OpenSearch with authentication
- `fluent-bit-opensearch-noauth.conf` - OpenSearch without authentication
- `fluent-bit-opensearch-optimized.conf` - **Recommended** for high-throughput (with auth)
- `fluent-bit-opensearch-noauth-optimized.conf` - **Recommended** for high-throughput (no auth)
- `parsers.conf` - Syslog format parsers (RFC3164 and RFC5424)

**Optimized configs include**:
- Filesystem buffering to prevent data loss during backpressure
- High retry limits with persistent storage
- Increased buffers for burst handling  
- Tuned flush intervals to prevent OpenSearch circuit breaker errors

**Important**: For throughput >10k msg/s, always use optimized configs with filesystem buffering and increased retry limits.

#### Alternative Outputs (Testing/Development)
- `fluent-bit-null.conf` - Discards output (baseline performance testing)
- `fluent-bit-file.conf` - Writes to file (I/O performance)
- `fluent-bit-http.conf` - Sends to generic HTTP endpoint
- `fluent-bit-stdout.conf` - Console output (debugging)

### 4. Helper Scripts

#### Primary Workflow
- `run_opensearch_benchmark.sh` - **Main script**: Run test with OpenSearch validation
- `validate_opensearch.py` - Validates message integrity and detects data loss
- `check_metrics.sh` - Real-time pipeline health monitoring
- `analyze_fluentbit_logs.sh` - Post-test log analysis for data loss indicators

#### Build and Development
- `build.sh` - Compiles the C++ injector
- `run_benchmark.sh` - Generic benchmark runner (any output)
- `run_all_benchmarks.sh` - Runs all predefined profiles
- `run_matrix_tests.sh` - Matrix testing (3 outputs × 4 profiles)
- `compare_results.py` - Multi-run performance comparison

## Quick Start

### Prerequisites
- **Required**:
  - C++ compiler with C++17 support (g++ or clang++)
  - Fluent-Bit installed and in PATH
  - OpenSearch cluster (accessible network endpoint)
  - Python 3 with standard library
  - Linux system with Unix socket support
  
- **Optional**:
  - CMake 3.10+ (can use Makefile instead)
  - jq (for enhanced metrics display)
  
- **OpenSearch Setup**:
  - Accessible HTTP/HTTPS endpoint
  - Authentication optional (supports both authenticated and open clusters)
  - Index creation permissions
  - Recommended: Circuit breaker configured (default 972MB usually sufficient)
- Optional: jq (for enhanced metrics display)
- Optional: OpenSearch cluster (for data integrity validation)

### Build
OpenSearch Benchmark (Recommended)

```bash
# Make scripts executable
chmod +x *.sh

# Configure OpenSearch connection
export OPENSEARCH_HOST="your-opensearch-host.example.com"
export OPENSEARCH_USER="admin"              # Optional: omit for no-auth
export OPENSEARCH_PASSWORD="your-password"  # Optional: omit for no-auth

# Run medium rate test (1000 msg/s for 60s = 60,000 messages)
./run_opensearch_benchmark.sh --profile medium_rate --optimized --cleanup

# Run high throughput test (10,000 msg/s for 60s = 600,000 messages)
./run_opensearch_benchmark.sh --profile high_rate --optimized --cleanup

# Without SSL (HTTP instead of HTTPS)
./run_opensearch_benchmark.sh --profile medium_rate --no-ssl --optimized --cleanup
```

This will:
1. Start Fluent-Bit with optimized configuration
2. Inject messages at specified rate
3. Wait for buffer flush (30 seconds)
4. Validate all messages in OpenSearch
5. Report data integrity results (gaps, duplicates, count)
6. Cleanup test index

### Alternative Testing (Non-OpenSearch)

```bash
# Baseline performance (null output)
./run_benchmark.sh -p high_rate -f configs/fluent-bit/fluent-bit-null.conf -m

# File output testing
./run_benchmark.sh -p medium_rate -f configs/fluent-bit/fluent-bit-file.conf -m

# Matrix test across multiple outputs
./run_matrix_tests.sh
```
```bash
# Run all profiles with null output
./run_all_benchmarks.sh

# Run matrix test (3 outputs × 4 profiles = 12 tests)
./run_matrix_tests.sh
```

This will run all four profiles sequentially and collect metrics for each.

## Configuration

### Injector Configuration Format

```ini
# Unix socket path (must match fluent-bit configuration)
socket_path = /tmp/fluentbit.sock

# Message format with placeholders
message_format = <134>1 {timestamp} {hostname} test-app {pid} - - Test message #{counter}

# Target message rate (messages per second)
target_rate = 1000

# Test duration in seconds
duration = 60

# Batch size (messages sent before sleeping)
batch_size = 100

# Verbose output (true/false)
verbose = false
```

### Available Placeholders
- `{timestamp}` - RFC3339 timestamp (e.g., 2026-02-12T10:30:45.123Z)
- `{hostname}` - System hostname
- `{pid}` - Process ID
- `{counter}` - Sequential message counter

### Syslog Message Fo for OpenSearch Stack

### Recommended Configuration (High Throughput)

Use the optimized configs which include:
- **Filesystem Buffering**: Prevents data loss during backpressure via persistent storage
- **Retry Configuration**: `Retry_Limit 10000` instead of default 3 attempts
- **Buffer Sizes**: `Buffer_Size 2M` to handle large OpenSearch responses
- **Flush Intervals**: `Flush 2s` to keep bulk requests under circuit breaker limit (972MB)
- **Input Buffers**: `Buffer_Size 256KB`, `Buffer_Max_Size 1MB` for controlled chunk growth

These settings prevent data loss during backpressure and circuit breaker scenarios.

### Capacity Planning Profiles

| Profile | Rate | Duration | Total Messages | Use Case |
|---------|------|----------|----------------|----------|
| `low_rate` | 100 msg/s | 30s | 3,000 | Baseline validation |
| `medium_rate` | 1,000 msg/s | 60s | 60,000 | Typical production load |
| `high_rate` | 10,000 msg/s | 60s | 600,000 | Peak load testing |
| `stress_test` | 50,000 msg/s | 120s | 6,000,000 | Stress testing and limits |

**Note**: `stress_test` will exceed most OpenSearch cluster capacities (~1k-5k msg/s typical). Use to identify breaking points and measure backpressure handling.

### OpenSearch Cluster Considerations

- **Index Refresh**: Default 1s may cause backpressure; consider 5-10s for ingestion workloads
- **Bulk Thread Pool**: Increase if seeing `queue_capacity_exception`
- **Circuit Breaker**: Monitor for HTTP 429 errors (default ~972MB per request)
- **Shard Count**: More shards = better write parallelism
- **Replica Count**: Set to 0 during ingestion benchmarks for maximum throughput
### For Maximum Performance:
1. Use `configs/fluent-bit/fluent-bit-null.conf` (discards output)
2. Increase `batch_size` in injector config (e.g., 500-1000)
3. Adjust Fluent-Bit's `Buffer_Chunk_Size` and `Buffer_Max_Size`
4. Disable verbose logging in Fluent-Bit (`Log_Level error`)

### For Realistic Testing:
1. Use `configs/fluent-bit/fluent-bit-http.conf` or `configs/fluent-bit/fluent-bit-file.conf`
2. Set up an actual HTTP endpoint or monitor file I/O
3. Use moderate batch sizes (100-200)
4. Monitor Fluent-Bit metrics via HTTP server (port 2020)

## Monitoring

### ⚠️ Important: Metrics vs Reality

**Fluent-bit metrics can show 100% success while 98% of your data is being lost!**

Fluent-bit reports when HTTP requests succeed, but doesn't know if:
- OpenSearch actually indexed the documents
- Documents were parsed correctly
- Fields were extracted properly
- Bulk API had partial failures

**Always validate data integrity**, especially for high-throughput tests. Fluent-Bit metrics show transport layer success, not data layer success.

### Real-time Metrics Monitoring

Monitor Fluent-bit metrics during tests:

```bash
# In a separate terminal while test runs
./check_metrics.sh
```

This displays:
- Input/output rates and lag
- Retry rates (backpressure indicator)
- Storage buffering status
- Warning indicators for potential issues

### Injector Statistics
The injector displays real-time statistics:
```
Elapsed: 10.5s | Messages: 10500 | Rate: 1000.00 msg/s | Throughput: 125.50 KB/s | Errors: 0
```

### Fluent-Bit Metrics API
When using `-m` flag, metrics are collected from Fluent-Bit's HTTP API:
```bash
curl http://localhost:2020/api/v1/metrics
```

### ResProduction Stack Validation (OpenSearch + Authentication)

```bash
# Full pipeline test with data integrity validation
export OPENSEARCH_HOST="your-cluster.example.com"
export OPENSEARCH_USER="admin"
export OPENSEARCH_PASSWORD="your-secure-password"

# Medium load test
./run_opensearch_benchmark.sh --profile medium_rate --optimized --cleanup

# High load test
./run_opensearch_benchmark.sh --profile high_rate --optimized --cleanup
```

### 2. Open/Development Cluster Testing (No Authentication)

```bash
# For OpenSearch clusters without security plugin
export OPENSEARCH_HOST="opensearch-dev.local"

# Test with HTTP (no SSL)
./run_opensearch_benchmark.sh --profile medium_rate --no-ssl --optimized --cleanup
```

### 3. Capacity Planning and Stress Testing

```bash
# Find your cluster's breaking point
export OPENSEARCH_HOST="your-cluster.example.com"

# Start conservative
./run_opensearch_benchmark.sh --profile low_rate --optimized

# Increase load
./run_opensearch_benchmark.sh --profile medium_rate --optimized

# Push to limits
./run_opensearch_benchmark.sh --profile high_rate --optimized

# Find failure modes
./run_opensearch_benchmark.sh --profile stress_test --optimized

# Monitor with check_metrics.sh in parallel terminal
```

### 4. Manual Data Validation (Existing Index)

```bash
# Validate an index without re-running the test
python3 validate_opensearch.py \
  --host opensearch.example.com \
  --user admin \
  --password your-password \
  --index fluentbit-bench-high_rate-20260212-120000 \
  --expected-count 600000
```

### 5. Real-time Monitoring During Tests

```bash
# Terminal 1: Run benchmark
./run_opensearch_benchmark.sh --profile stress_test --optimized --no-ssl

# Terminal 2: Monitor metrics
./check_metrics.sh

# Watch for:
# - LAG growing = backpressure
# - RETRY_RATE > 0 = OpenSearch rejections
# - OUTPUT_RATE << INPUT_RATE = pipeline bottleneck
```

### 6. Post-Test Log Analysis

```bash
# Analyze latest Fluent-Bit log for issues
./analyze_fluentbit_logs.sh results/fluentbit_20260212_190209.log

# Look for:
# - Buffer size errors (need larger Buffer_Size)
# - Circuit breaker errors (need smaller Flush interval)
# - Retry errors (check OpenSearch health)
```

### 7. Baseline Performance Testing (Non-OpenSearch)

```bash
# Test pure Fluent-Bit performance (null output)
./run_benchmark.sh -p stress_test -f configs/fluent-bit/fluent-bit-null.conf -m

# File I/O performance
./run_benchmark.sh -p high_rate -f configs/fluent-bit/fluent-bit-file.conf -m
```

### 8

### 3. HTTP Endpoint Performance
```bash
# First, start an HTTP server to receive data
python3 -m http.server 8080 &

# Run benchmark with HTTP output
./run_benchmark.sh -p medium_rate -f configs/fluent-bit/fluent-bit-http.conf -m
```

### 3. File Output Performance
```bash
# Test file writing performance
./run_benchmark.sh -p high_rate -f configs/fluent-bit/fluent-bit-file.conf -m

# Check output file
cat /tmp/fluentbit-output/output.log
```

### 5. Matrix Performance Test
```bash
# Run all combinations (3 outputs × 4 profiles)
./run_matrix_tests.sh

# Results saved to results/matrix_TIMESTAMP/
# Summary report at results/matrix_summary_TIMESTAMP.md
```

### 6. Custom Message Format
Edit `configs/injector/default.conf`:
```ini
message_format = <134>1 {timestamp} {hostname} my-app {pid} - [custom@12345 key="value"] Custom message #{counter}
duration = 30
```Data Loss Despite "Perfect" Metrics

**Problem**: Fluent-Bit shows 100% success rate but validation finds missing messages.

**Cause**: Fluent-Bit tracks HTTP request success, not OpenSearch indexing success. Bulk API can accept requests but partially fail document indexing without returning HTTP errors.

**Solutions**:
1. Check Fluent-Bit logs: `./analyze_fluentbit_logs.sh results/fluentbit_*.log`
2. Look for buffer errors (increase `Buffer_Size`)
3. Look for circuit breaker errors (decrease `Flush` interval or increase OpenSearch limit)
4. Check for retry errors (verify `Retry_Limit` is numeric, not "False")
5. Use optimized configs for throughput >10k msg/s
6. Monitor real-time with `./check_metrics.sh` - watch for growing LAG

### OpenSearch Circuit Breaker (HTTP 429)

**Symptom**: Errors like "circuit_breaking_exception" or "Data too large"

**Cause**: Bulk requests exceeding OpenSearch circuit breaker limit (~972MB default)

**Solution**:
- Reduce `Flush` interval: 5s → 2s (reduces chunk size)
- At 50k msg/s: 2s flush = ~400MB chunks (safe), 5s flush = ~1GB chunks (exceeds limit)
- Or increase OpenSearch circuit breaker: `indices.breaker.request.limit: 60%` → `80%`

### Buffer Size Errors

**Symptom**: `[warn] [http_client] cannot increase buffer: current=1000000 requested=1032768`

**Cause**: `Buffer_Size` too small for OpenSearch bulk API responses

**Solution**: Increase `Buffer_Size` in Fluent-Bit output config:
```
Buffer_Size     2M     # Was 1M, need 2M for 1MB+ responses
```

### High Input Rate, Low Output Rate

**Symptom**: Injector sends 50k msg/s, OpenSearch receives 1k msg/s

**Cause**: OpenSearch backpressure - cluster cannot keep up with ingestion rate

**What's happening**: Fluent-Bit's filesystem buffer accumulates messages, retries slowly

**Solutions**:
- **Scale OpenSearch**: Add nodes, increase resources
- **Optimize OpenSearch**: Increase refresh interval, reduce replicas during ingestion
- **Reduce injection rate**: Lower test profile to match cluster capacity
- **This is normal**: Use to measure maximum sustainable rate for capacity planning

### OpenSearch Connection Issues
- Verify endpoint: `curl -k https://opensearch.example.com:9200`
- Check credentials are correct
- Ensure SSL settings match (`--no-ssl` if using HTTP)
- Check index was created: query OpenSearch API or dashboard
- Verify network connectivity and firewall rules
- Check OpenSearch cluster health: `/_cluster/health`
```

## Data Integrity Validation

The benchmark suite includes comprehensive data validation when using OpenSearch output:

### What Gets Validated
- **Message Count**: Total messages received vs sent
- **Sequence Integrity**: Checks for gaps in message counter sequence
- **Duplicates**: Detects duplicate message counters
- **Message Range**: Verifies first and last counter values

### Validation Process
1. Messages contain counter: `Test message #N`
2. After test completes, validator queries OpenSearch
3. Extracts all counters and sorts them
4. Checks for gaps: missing sequence numbers
5. Checks for duplicates: repeated sequence numbers
6. Reports detailed results with pass/fail status

### Example Output
```
=== Validation Results ===
Messages found: 3000
Counter range: 0 to 2999
Count match: ✓ PASS
Sequence integrity: ✓ ────────────────────────────────────┐
│                    Benchmark Suite                       │
│                                                           │
│  ┌───────────────────┐      ┌─────────────────────┐    │
│  │ Syslog Injector   │      │  Monitoring Tools   │    │
│  │ (C++ Application) │      │                     │    │
│  │                   │      │  - check_metrics.sh │    │
│  │ - Rate control    │      │  - analyze_logs.sh  │    │
│  │ - Counter tagging │      │  - Real-time stats  │    │
│  │ - Statistics      │      └─────────────────────┘    │
│  └─────────┬─────────┘                                  │
│            │                                             │
└────────────┼─────────────────────────────────────────────┘
             │
             │ Unix Socket (/tmp/fluentbit.sock)
             │ RFC5424 Syslog Messages
             ▼
┌─────────────────────────────────────────────────────────┐
│                      Fluent-Bit                          │
│                                                           │
│  INPUT: syslog (mode unix_udp)                          │
│    - Parse RFC5424                                       │
│    - Extract fields                                      │
│    - Buffer_Size 256KB, Buffer_Max_Size 1MB             │
│                                                           │
│  STORAGE: filesystem (optimized config)                  │
│    - Path: /tmp/fluentbit-buffer/                       │
│    - Persistent retry buffer                             │
│    - Backlog:Expectations

### Fluent-Bit Performance (Local)
- **Null Output**: 50,000+ msg/s (baseline, CPU-bound)
- **File Output**: 10,000-30,000 msg/s (I/O-bound)
- **Stdout Output**: 1,000-5,000 msg/s (terminal-bound)

### OpenSearch Stack Performance (Typical)
- **Small Cluster** (3 nodes, 4GB heap): 1,000-3,000 msg/s sustained
- **Medium Cluster** (6 nodes, 8GB heap): 3,000-8,000 msg/s sustained
- **Large Cluster** (10+ nodes, 16GB heap): 10,000-20,000 msg/s sustained

**Factors affecting OpenSearch throughput**:
- Network latency between Fluent-Bit and OpenSearch
- OpenSearch cluster size and resource allocation
- Index settings (refresh interval, replicas, shards)
- Document size (~4KB per syslog message in this benchmark)
- Bulk request size and flush intervals
- Concurrent indexing operations
- Circuit breaker limits (default 972MB per request)

### Validation Performance
- **Scroll API**: Processes 10,000 documents per batch
- **Typical validation time**: 5-15 seconds for 60,000 messages
- **Large datasets**: 30-60 seconds for 1,000,000+ messages     │
│  METRICS: http_server (port 2020)                       │
└─────────────────┬───────────────────────────────────────┘
                  │
                  │ HTTPS Bulk API
                  │ JSON Documents
                  ▼
┌─────────────────────────────────────────────────────────┐
│                     OpenSearch Cluster                   │
│                                                           │
│  - Index documents (syslog-* pattern)                   │
│  - Parse and store fields                                │
│  - Circuit breaker: 972MB limit                          │
│  - Bulk thread pool processing                           │
└─────────────────┬───────────────────────────────────────┘
                  │
                  │ Query/Validation
                  │ Scroll API
                  ▼
┌─────────────────────────────────────────────────────────┐
│               Validation Script (Python)                 │
│                                                           │
│  - Query total document count                            │
│  - Extract message counters (scroll API)                │
│  - Detect gaps in sequence                               │
│  - Detect duplicates                                     │
│  - Generate integrity report                             │
│                                                           │
│  ✓ PASS: 60,000/60,000 messages, no gaps                │
│  ✗ FAIL: 44,784/60,000 messages, 15,216 lost            │
└────────────────────────────────────## Build Errors
- Ensure g++ or clang++ is installed: `g++ --version`
- Check C++17 support: `g++ -std=c++17 --version`
- Install pthread library: `sudo apt-get install libpthread-stubs0-dev`

### Permission Denied on Socket
- Check socket permissions: `ls -la /tmp/fluentbit.sock`
- Adjust `Unix_Perm` in Fluent-Bit config
- Run with appropriate user permissions

## Architecture

```
┌─────────────────────┐
│  Syslog Injector    │
│  (C++ Application)  │
│                     │
│  - Reads config     │
│  - Formats messages │
│  - Controls rate    │
│  - Tracks stats     │
└──────────┬──────────┘
           │
           │ Unix Socket
           │ /tmp/fluentbit.sock
           ▼
┌─────────────────────┐
│    Fluent-Bit       │
│                     │
│  INPUT: syslog      │
│  - Parse messages   │
│  - Buffer data      │
│                     │
│  OUTPUT: null/file/ │
│          http/stdout│
│          /opensearch│
│  - Forward data     │
│  - Track metrics    │
└─────────────────────┘
```

## Performance Metrics

Expected performance (varies by hardware):
- **Null Output**: 50,000+ msg/s (pure processing)
- **File Output**: 10,000-30,000 msg/s (I/O bound)
- **HTTP Output**: 5,000-15,000 msg/s (network bound)
- **OpenSearch Output**: 5,000-20,000 msg/s (network + indexing bound)
- **Stdout Output**: 1,000-5,000 msg/s (terminal bound)

## Contributing

### Adding New Test Profiles
1. Create config file: `configs/injector/profiles/your-profile.conf`
2. Set `target_rate`, `duration`, and `batch_size`
3. Run: `./run_opensearch_benchmark.sh --profile your-profile --optimized`

### Adding OpenSearch Configuration Variants
1. Create: `configs/fluent-bit/fluent-bit-opensearch-variant.conf`
2. Base on existing optimized config
3. Adjust buffer sizes, flush intervals, retry limits as needed
4. Test with various profiles to validate
5. Document configuration choices

### Customizing Validation
The validation script can be extended to check:
- Custom field extraction
- Message format validation
- Timestamp accuracy
- GeoIP enrichment correctness
- Custom parsing logic

Edit `validate_opensearch.py` and adjust the counter extraction regex or add new validation logic.

## Advanced Features

### Comprehensive Data Integrity Validation
The validation system ensures data quality across the entire pipeline:
- **Message Counter Tracking**: Each message tagged with sequential counter
- **Scroll API**: Efficiently processes millions of documents in batches
- **Gap Detection**: Identifies missing sequence numbers
- **Duplicate Detection**: Finds repeated messages
- **Statistical Analysis**: Reports on data loss percentage and patterns

### Real-time Pipeline Monitoring
Monitor Fluent-Bit and OpenSearch health during tests:
- **Input vs Output Rates**: Detect backpressure immediately
- **Buffer Utilization**: Track filesystem buffer growth
- **Retry Rates**: Measure OpenSearch rejection frequency
- **Lag Calculation**: See accumulated backlog in real-time

### Matrix Testing
Run comprehensive test matrix across multiple configurations:
- Tests all combinations of outputs and profiles
- Generates comparative summary report in markdown
- Useful for capacity planning and performance analysis
- Identifies optimal configuration for your infrastructure

### Log Analysis Tools
Post-benchmark suite is provided as-is for observability infrastructure evaluation and capacity planning purposes.

## References

### Documentation
- [Fluent-Bit Documentation](https://docs.fluentbit.io/)
- [Fluent-Bit Syslog Input Plugin](https://docs.fluentbit.io/manual/data-pipeline/inputs/syslog)
- [Fluent-Bit OpenSearch Output Plugin](https://docs.fluentbit.io/manual/pipeline/outputs/opensearch)
- [OpenSearch Documentation](https://opensearch.org/docs/latest/)
- [OpenSearch Bulk API](https://opensearch.org/docs/latest/api-reference/document-apis/bulk/)

### RFCs and Standards
- [RFC5424 - The Syslog Protocol](https://tools.ietf.org/html/rfc5424)
- [RFC3164 - BSD Syslog Protocol](https://tools.ietf.org/html/rfc3164)
- [RFC3339 - Date and Time on the Internet: Timestamps](https://tools.ietf.org/html/rfc3339)

### Performance Tuning Resources
- [OpenSearch Performance Tuning](https://opensearch.org/docs/latest/tuning-your-cluster/)
- [Fluent-Bit Buffering](https://docs.fluentbit.io/manual/administration/buffering-and-storage)
- [Fluent-Bit Backpressure](https://docs.fluentbit.io/manual/administration/backpressure
- `OPENSEARCH_HOST`, `OPENSEARCH_PORT` - Connection details
- `OPENSEARCH_USER`, `OPENSEARCH_PASSWORD` - Authentication (optional)
- `USE_SSL` - Enable/disable TLS
- `OPENSEARCH_INDEX` - Custom index naming
- `OPENSEARCH_TLS` - TLS toggle for Fluent-Bit config

## License

This testbench is provided as-is for performance evaluation purposes.

## References

- [Fluent-Bit Documentation](https://docs.fluentbit.io/)
- [Syslog Input Plugin](https://docs.fluentbit.io/manual/data-pipeline/inputs/syslog)
- [RFC5424 - Syslog Protocol](https://tools.ietf.org/html/rfc5424)
- [RFC3164 - BSD Syslog Protocol](https://tools.ietf.org/html/rfc3164)
