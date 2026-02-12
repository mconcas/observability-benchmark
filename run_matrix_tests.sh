#!/bin/bash
# Run a matrix of benchmark tests across different profiles and fluent-bit configurations
# Generates a comprehensive summary in markdown format

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test matrix configuration
PROFILES=("low_rate" "medium_rate" "high_rate" "stress_test")
FB_CONFIGS=("configs/fluent-bit/fluent-bit-null.conf" "configs/fluent-bit/fluent-bit-file.conf" "configs/fluent-bit/fluent-bit-http.conf")
FB_CONFIG_NAMES=("null" "file" "http")

# Output directory
OUTPUT_DIR="results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_FILE="$OUTPUT_DIR/matrix_summary_${TIMESTAMP}.md"
MATRIX_DIR="$OUTPUT_DIR/matrix_${TIMESTAMP}"

# Create matrix results directory
mkdir -p "$MATRIX_DIR"

# Initialize summary file
cat > "$SUMMARY_FILE" << 'EOF'
# Fluent-Bit Performance Matrix Test Results

This document contains the results of a comprehensive performance test matrix evaluating Fluent-Bit's syslog input plugin across different message rates and output configurations.

## Test Matrix

- **Profiles**: Low Rate (100 msg/s), Medium Rate (1K msg/s), High Rate (10K msg/s), Stress Test (50K msg/s)
- **Output Configurations**: Null (discard), File (write to disk), HTTP (network output)
- **Total Tests**: 12 combinations

EOF

echo "Test timestamp: $(date)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Fluent-Bit Matrix Performance Test  ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Total tests to run: $((${#PROFILES[@]} * ${#FB_CONFIGS[@]}))"
echo "Results directory: $MATRIX_DIR"
echo "Summary file: $SUMMARY_FILE"
echo ""

# Array to store results for summary table
declare -a RESULTS

# Counter for progress
TEST_NUM=0
TOTAL_TESTS=$((${#PROFILES[@]} * ${#FB_CONFIGS[@]}))

# Run matrix tests
for profile in "${PROFILES[@]}"; do
    for i in "${!FB_CONFIGS[@]}"; do
        fb_config="${FB_CONFIGS[$i]}"
        fb_name="${FB_CONFIG_NAMES[$i]}"

        TEST_NUM=$((TEST_NUM + 1))

        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}Test $TEST_NUM/$TOTAL_TESTS: Profile=$profile, Output=$fb_name${NC}"
        echo -e "${GREEN}========================================${NC}"

        # Run the benchmark
        TEST_OUTPUT="$MATRIX_DIR/${profile}_${fb_name}.txt"

        if ./run_benchmark.sh -p "$profile" -f "$fb_config" -m -o "$MATRIX_DIR" > "$TEST_OUTPUT" 2>&1; then
            echo -e "${GREEN}✓ Test completed successfully${NC}"

            # Extract results from the output
            INJECTOR_RATE=$(grep "^=== Final Statistics ===" "$TEST_OUTPUT" -A 1 | grep "Rate:" | sed -n 's/.*Rate: \([0-9.]*\) msg\/s.*/\1/p')
            INJECTOR_THROUGHPUT=$(grep "^=== Final Statistics ===" "$TEST_OUTPUT" -A 1 | grep "Throughput:" | sed -n 's/.*Throughput: \([0-9.]*\) KB\/s.*/\1/p')
            MESSAGES=$(grep "^=== Final Statistics ===" "$TEST_OUTPUT" -A 1 | grep "Messages:" | sed -n 's/.*Messages: \([0-9]*\).*/\1/p')
            ERRORS=$(grep "^=== Final Statistics ===" "$TEST_OUTPUT" -A 1 | grep "Errors:" | sed -n 's/.*Errors: \([0-9]*\)/\1/p')

            # Try to extract Fluent-bit metrics
            FB_INPUT=$(grep "Fluent-bit Input records:" "$TEST_OUTPUT" | awk '{print $NF}')
            FB_OUTPUT=$(grep "Fluent-bit Output records:" "$TEST_OUTPUT" | awk '{print $NF}')
            FB_ERRORS=$(grep "Fluent-bit Errors:" "$TEST_OUTPUT" | awk '{print $NF}')

            # Store results
            RESULTS+=("$profile|$fb_name|$MESSAGES|$INJECTOR_RATE|$INJECTOR_THROUGHPUT|$FB_INPUT|$FB_OUTPUT|$ERRORS")

        else
            echo -e "${RED}✗ Test failed${NC}"
            RESULTS+=("$profile|$fb_name|FAILED|N/A|N/A|N/A|N/A|N/A")
        fi

        echo ""

        # Wait between tests
        if [ $TEST_NUM -lt $TOTAL_TESTS ]; then
            echo "Waiting 5 seconds before next test..."
            sleep 5
        fi
    done
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  All tests completed!                ${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Generate summary table
cat >> "$SUMMARY_FILE" << 'EOF'

## Results Summary

### Performance Table

| Profile | Output | Messages Sent | Injector Rate (msg/s) | Injector Throughput (KB/s) | FB Input | FB Output | Errors |
|---------|--------|---------------|----------------------|----------------------------|----------|-----------|--------|
EOF

# Add results to table
for result in "${RESULTS[@]}"; do
    IFS='|' read -r profile fb_name messages rate throughput fb_input fb_output errors <<< "$result"
    printf "| %-11s | %-6s | %13s | %20s | %26s | %8s | %9s | %6s |\n" \
        "$profile" "$fb_name" "$messages" "$rate" "$throughput" "$fb_input" "$fb_output" "$errors" >> "$SUMMARY_FILE"
done

# Add analysis section
cat >> "$SUMMARY_FILE" << 'EOF'

## Analysis

### Key Findings

EOF

# Calculate some statistics if jq is available
if command -v jq &> /dev/null; then
    echo "Analyzing results..."

    # Find best performing configurations
    BEST_RATE=$(printf '%s\n' "${RESULTS[@]}" | grep -v "FAILED" | awk -F'|' '{print $4}' | sort -n | tail -1)
    BEST_RATE_CONFIG=$(printf '%s\n' "${RESULTS[@]}" | grep "$BEST_RATE" | head -1)

    if [ ! -z "$BEST_RATE_CONFIG" ]; then
        IFS='|' read -r profile fb_name messages rate throughput fb_input fb_output errors <<< "$BEST_RATE_CONFIG"
        cat >> "$SUMMARY_FILE" << EOF
- **Highest Message Rate**: $rate msg/s achieved with profile \`$profile\` and output \`$fb_name\`
EOF
    fi
fi

cat >> "$SUMMARY_FILE" << 'EOF'

### Output Configuration Impact

- **Null Output**: Provides baseline maximum throughput (data is discarded)
- **File Output**: Shows disk I/O impact on performance
- **HTTP Output**: Demonstrates network/endpoint overhead

### Profile Comparison

- **Low Rate** (100 msg/s): Baseline test for correctness and stability
- **Medium Rate** (1K msg/s): Typical production load
- **High Rate** (10K msg/s): Heavy load scenario
- **Stress Test** (50K msg/s): Maximum capability assessment

## Raw Data

Individual test results can be found in:
```
EOF

echo "$MATRIX_DIR/" >> "$SUMMARY_FILE"
echo '```' >> "$SUMMARY_FILE"

cat >> "$SUMMARY_FILE" << 'EOF'

## Test Environment

EOF

# Add system information
echo "- **Date**: $(date)" >> "$SUMMARY_FILE"
echo "- **Hostname**: $(hostname)" >> "$SUMMARY_FILE"
echo "- **CPU**: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)" >> "$SUMMARY_FILE"
echo "- **CPU Cores**: $(nproc)" >> "$SUMMARY_FILE"
echo "- **Memory**: $(free -h | grep Mem | awk '{print $2}')" >> "$SUMMARY_FILE"
echo "- **OS**: $(uname -sr)" >> "$SUMMARY_FILE"

if command -v fluent-bit &> /dev/null; then
    echo "- **Fluent-bit Version**: $(fluent-bit --version 2>&1 | head -1)" >> "$SUMMARY_FILE"
fi

cat >> "$SUMMARY_FILE" << 'EOF'

## Conclusion

This matrix test provides comprehensive performance data for evaluating Fluent-Bit's syslog input plugin under various conditions. Use these results to:

1. Understand baseline performance capabilities
2. Identify bottlenecks in different output configurations
3. Plan capacity for production deployments
4. Compare performance across different message rates

EOF

echo ""
echo -e "${GREEN}Matrix test complete!${NC}"
echo -e "Summary report: ${GREEN}$SUMMARY_FILE${NC}"
echo -e "Raw results: ${GREEN}$MATRIX_DIR/${NC}"
echo ""

# Display summary
if command -v cat &> /dev/null; then
    echo -e "${YELLOW}Quick Summary:${NC}"
    echo ""
    grep -A 100 "^| Profile" "$SUMMARY_FILE" | head -20
fi
