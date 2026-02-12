#!/bin/bash
# Monitor Fluent-bit metrics during benchmark
# Shows what metrics look like and what they actually mean

set -e

METRICS_URL="${FLUENT_BIT_METRICS_URL:-http://localhost:2020/api/v1/metrics/prometheus}"
INTERVAL="${INTERVAL:-5}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Fluent-bit Metrics Monitor ===${NC}"
echo "Fetching from: $METRICS_URL"
echo "Update interval: ${INTERVAL}s"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# Track previous values for rate calculation
PREV_INPUT_RECORDS=0
PREV_OUTPUT_RECORDS=0
PREV_OUTPUT_RETRIES=0
PREV_OUTPUT_ERRORS=0
PREV_TIME=$(date +%s)

while true; do
    METRICS=$(curl -s "$METRICS_URL" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Cannot fetch metrics from $METRICS_URL${NC}"
        echo "Make sure Fluent-bit is running with HTTP_Server enabled"
        exit 1
    fi

    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - PREV_TIME))

    # Extract key metrics
    INPUT_RECORDS=$(echo "$METRICS" | grep '^fluentbit_input_records_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    INPUT_BYTES=$(echo "$METRICS" | grep '^fluentbit_input_bytes_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')

    OUTPUT_RECORDS=$(echo "$METRICS" | grep '^fluentbit_output_proc_records_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    OUTPUT_BYTES=$(echo "$METRICS" | grep '^fluentbit_output_proc_bytes_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')

    OUTPUT_RETRIES=$(echo "$METRICS" | grep '^fluentbit_output_retries_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    OUTPUT_RETRIES_FAILED=$(echo "$METRICS" | grep '^fluentbit_output_retries_failed_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    OUTPUT_ERRORS=$(echo "$METRICS" | grep '^fluentbit_output_errors_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    OUTPUT_DROPPED=$(echo "$METRICS" | grep '^fluentbit_output_dropped_records_total' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')

    # Storage metrics (if filesystem buffering enabled)
    STORAGE_CHUNKS_UP=$(echo "$METRICS" | grep '^fluentbit_storage_chunks_up{' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')
    STORAGE_CHUNKS_DOWN=$(echo "$METRICS" | grep '^fluentbit_storage_chunks_down{' | grep -v '#' | awk '{sum+=$2} END {print sum+0}')

    # Calculate rates
    if [ $ELAPSED -gt 0 ]; then
        INPUT_RATE=$(( (INPUT_RECORDS - PREV_INPUT_RECORDS) / ELAPSED ))
        OUTPUT_RATE=$(( (OUTPUT_RECORDS - PREV_OUTPUT_RECORDS) / ELAPSED ))
        RETRY_RATE=$(( (OUTPUT_RETRIES - PREV_OUTPUT_RETRIES) / ELAPSED ))
        ERROR_RATE=$(( (OUTPUT_ERRORS - PREV_OUTPUT_ERRORS) / ELAPSED ))
    else
        INPUT_RATE=0
        OUTPUT_RATE=0
        RETRY_RATE=0
        ERROR_RATE=0
    fi

    # Calculate lag (difference between input and output)
    LAG=$((INPUT_RECORDS - OUTPUT_RECORDS))

    clear
    echo -e "${BLUE}=== Fluent-bit Metrics Monitor ===${NC}"
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    echo -e "${GREEN}INPUT (Received)${NC}"
    printf "  Records: %'15d  |  Rate: %'8d/s  |  Bytes: %'15d\n" $INPUT_RECORDS $INPUT_RATE $INPUT_BYTES
    echo ""

    echo -e "${GREEN}OUTPUT (Sent to OpenSearch)${NC}"
    printf "  Records: %'15d  |  Rate: %'8d/s  |  Bytes: %'15d\n" $OUTPUT_RECORDS $OUTPUT_RATE $OUTPUT_BYTES
    echo ""

    # Lag indicator
    if [ $LAG -gt 1000 ]; then
        echo -e "${RED}⚠ LAG: $LAG records behind (OUTPUT < INPUT)${NC}"
    elif [ $LAG -gt 100 ]; then
        echo -e "${YELLOW}⚠ LAG: $LAG records behind (OUTPUT < INPUT)${NC}"
    else
        echo -e "${GREEN}✓ LAG: $LAG records${NC}"
    fi
    echo ""

    echo -e "${YELLOW}RELIABILITY${NC}"
    printf "  Retries:        %'15d  |  Rate: %'8d/s\n" $OUTPUT_RETRIES $RETRY_RATE
    printf "  Failed Retries: %'15d\n" $OUTPUT_RETRIES_FAILED
    printf "  Errors:         %'15d  |  Rate: %'8d/s\n" $OUTPUT_ERRORS $ERROR_RATE
    printf "  Dropped:        %'15d\n" $OUTPUT_DROPPED

    # Warning indicators
    if [ $OUTPUT_RETRIES_FAILED -gt 0 ]; then
        echo -e "  ${RED}⚠ FAILED RETRIES DETECTED - MESSAGES LOST!${NC}"
    fi
    if [ $OUTPUT_DROPPED -gt 0 ]; then
        echo -e "  ${RED}⚠ DROPPED RECORDS DETECTED - MESSAGES LOST!${NC}"
    fi
    if [ $RETRY_RATE -gt 10 ]; then
        echo -e "  ${YELLOW}⚠ High retry rate - output experiencing backpressure${NC}"
    fi
    echo ""

    if [ $STORAGE_CHUNKS_UP -gt 0 ] || [ $STORAGE_CHUNKS_DOWN -gt 0 ]; then
        echo -e "${BLUE}STORAGE (Filesystem Buffering)${NC}"
        printf "  Chunks Up (memory):  %'10d\n" $STORAGE_CHUNKS_UP
        printf "  Chunks Down (disk):  %'10d\n" $STORAGE_CHUNKS_DOWN

        if [ $STORAGE_CHUNKS_DOWN -gt 100 ]; then
            echo -e "  ${YELLOW}⚠ High disk buffering - significant backpressure${NC}"
        fi
        echo ""
    fi

    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} Fluent-bit metrics show messages ${YELLOW}sent${NC}, not messages ${YELLOW}indexed${NC}!"
    echo ""
    echo "What these metrics DON'T show:"
    echo "  • OpenSearch accepting requests but dropping documents internally"
    echo "  • OpenSearch indexing failures (parsing errors, mapping conflicts)"
    echo "  • Documents indexed but with missing/corrupted fields"
    echo "  • Bulk API partial failures (some docs succeed, others fail)"
    echo ""
    echo "Use validate_opensearch.py after the test to verify actual data integrity!"
    echo ""

    # Update previous values
    PREV_INPUT_RECORDS=$INPUT_RECORDS
    PREV_OUTPUT_RECORDS=$OUTPUT_RECORDS
    PREV_OUTPUT_RETRIES=$OUTPUT_RETRIES
    PREV_OUTPUT_ERRORS=$OUTPUT_ERRORS
    PREV_TIME=$CURRENT_TIME

    sleep $INTERVAL
done
