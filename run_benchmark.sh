#!/bin/bash
# Run benchmark script for Fluent-Bit Syslog performance testing

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
CONFIG="configs/injector/default.conf"
FB_CONFIG="configs/fluent-bit/fluent-bit-null.conf"
OUTPUT_DIR="results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -c, --config FILE         Injector config file (default: injector_config.conf)
    -f, --fluent-config FILE  Fluent-bit config file (default: fluent-bit-null.conf)
    -p, --profile NAME        Use predefined profile (low_rate, medium_rate, high_rate, stress_test)
    -o, --output DIR          Output directory for results (default: results)
    -m, --metrics             Collect fluent-bit metrics during test
    -h, --help                Show this help message

Examples:
    # Run with default configuration
    $0

    # Run with specific profile
    $0 -p high_rate

    # Run with custom configs and metrics collection
    $0 -c custom.conf -f fluent-bit-http.conf -m

Available fluent-bit configs:
    - fluent-bit-null.conf   : Discard output (for maximum performance testing)
    - fluent-bit-stdout.conf : Output to stdout
    - fluent-bit-file.conf   : Output to file
    - fluent-bit-http.conf   : Output to HTTP endpoint
EOF
    exit 0
}

# Parse arguments
COLLECT_METRICS=0
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG="$2"
            shift 2
            ;;
        -f|--fluent-config)
            FB_CONFIG="$2"
            shift 2
            ;;
        -p|--profile)
            CONFIG="configs/injector/profiles/$2.conf"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -m|--metrics)
            COLLECT_METRICS=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            usage
            ;;
    esac
done

# Check if injector binary exists
if [ ! -f "./syslog_injector" ]; then
    echo -e "${RED}Error: syslog_injector binary not found. Build it first with 'make' or 'cmake'${NC}"
    exit 1
fi

# Check if config files exist
if [ ! -f "$CONFIG" ]; then
    echo -e "${RED}Error: Injector config file '$CONFIG' not found${NC}"
    exit 1
fi

if [ ! -f "$FB_CONFIG" ]; then
    echo -e "${RED}Error: Fluent-bit config file '$FB_CONFIG' not found${NC}"
    exit 1
fi

# Check if fluent-bit is in PATH
if ! command -v fluent-bit &> /dev/null; then
    echo -e "${RED}Error: fluent-bit not found in PATH${NC}"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/benchmark_${TIMESTAMP}.txt"

echo -e "${GREEN}=== Fluent-Bit Syslog Benchmark ===${NC}"
echo "Timestamp: $TIMESTAMP"
echo "Injector config: $CONFIG"
echo "Fluent-bit config: $FB_CONFIG"
echo "Results will be saved to: $RESULT_FILE"
echo ""

# Clean up any existing socket
rm -f /tmp/fluentbit.sock

# Start fluent-bit in background
echo -e "${YELLOW}Starting fluent-bit...${NC}"
fluent-bit -c "$FB_CONFIG" > "$OUTPUT_DIR/fluentbit_${TIMESTAMP}.log" 2>&1 &
FB_PID=$!

# Function to cleanup on exit
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    if [ ! -z "$FB_PID" ]; then
        # Send SIGTERM for graceful shutdown
        kill -TERM $FB_PID 2>/dev/null || true
        # Wait up to 5 seconds for graceful shutdown
        for i in {1..10}; do
            if ! kill -0 $FB_PID 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        # Force kill if still running
        kill -KILL $FB_PID 2>/dev/null || true
        wait $FB_PID 2>/dev/null || true
    fi
    rm -f /tmp/fluentbit.sock
}

trap cleanup EXIT INT TERM

# Wait for socket to be created
echo "Waiting for fluent-bit socket..."
for i in {1..30}; do
    if [ -S "/tmp/fluentbit.sock" ]; then
        echo -e "${GREEN}Socket ready${NC}"
        break
    fi
    sleep 0.5
done

if [ ! -S "/tmp/fluentbit.sock" ]; then
    echo -e "${RED}Error: Socket not created after 15 seconds${NC}"
    exit 1
fi

# Optional: Collect metrics before test
if [ $COLLECT_METRICS -eq 1 ]; then
    echo "Collecting pre-test metrics..."
    sleep 1  # Give Fluent-bit a moment to fully start
    curl -s http://localhost:2020/api/v1/metrics > "$OUTPUT_DIR/metrics_before_${TIMESTAMP}.json" || true
fi

# Run the injector
echo -e "${GREEN}Starting injector...${NC}"
echo ""

# Save test info to result file
{
    echo "=== Fluent-Bit Syslog Benchmark Results ==="
    echo "Timestamp: $TIMESTAMP"
    echo "Injector Config: $CONFIG"
    echo "Fluent-bit Config: $FB_CONFIG"
    echo "=========================================="
    echo ""
} > "$RESULT_FILE"

# Run injector and tee output to both console and file
./syslog_injector "$CONFIG" 2>&1 | tee -a "$RESULT_FILE"

# Optional: Collect metrics after test
if [ $COLLECT_METRICS -eq 1 ]; then
    echo ""
    echo "Waiting for Fluent-bit to flush buffers..."
    sleep 30

    echo "Collecting post-test metrics..."
    curl -s http://localhost:2020/api/v1/metrics > "$OUTPUT_DIR/metrics_after_${TIMESTAMP}.json" || true

    # Show metrics diff if available
    if command -v jq &> /dev/null; then
        echo ""
        echo "=== Fluent-bit Metrics Summary ===" | tee -a "$RESULT_FILE"

        BEFORE="$OUTPUT_DIR/metrics_before_${TIMESTAMP}.json"
        AFTER="$OUTPUT_DIR/metrics_after_${TIMESTAMP}.json"

        if [ -f "$AFTER" ]; then
            INPUT_RECORDS=$(jq -r '(.input | to_entries | .[0].value.records) // "N/A"' "$AFTER" 2>/dev/null)
            INPUT_BYTES=$(jq -r '(.input | to_entries | .[0].value.bytes) // "N/A"' "$AFTER" 2>/dev/null)
            OUTPUT_RECORDS=$(jq -r '(.output | to_entries | .[0].value.proc_records) // (.output | to_entries | .[0].value.records) // "N/A"' "$AFTER" 2>/dev/null)
            OUTPUT_BYTES=$(jq -r '(.output | to_entries | .[0].value.proc_bytes) // (.output | to_entries | .[0].value.bytes) // "N/A"' "$AFTER" 2>/dev/null)
            ERRORS=$(jq -r '(.output | to_entries | .[0].value.errors) // "N/A"' "$AFTER" 2>/dev/null)

            echo "Fluent-bit Input records: $INPUT_RECORDS" | tee -a "$RESULT_FILE"
            echo "Fluent-bit Input bytes: $INPUT_BYTES" | tee -a "$RESULT_FILE"
            echo "Fluent-bit Output records: $OUTPUT_RECORDS" | tee -a "$RESULT_FILE"
            echo "Fluent-bit Output bytes: $OUTPUT_BYTES" | tee -a "$RESULT_FILE"
            echo "Fluent-bit Errors: $ERRORS" | tee -a "$RESULT_FILE"
        fi
    fi
fi

echo ""
echo -e "${GREEN}Test completed!${NC}"
echo -e "Results saved to: ${GREEN}$RESULT_FILE${NC}"
echo -e "Fluent-bit log: ${GREEN}$OUTPUT_DIR/fluentbit_${TIMESTAMP}.log${NC}"

# Cleanup is handled by trap
