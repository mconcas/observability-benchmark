#!/bin/bash
# Run benchmark with OpenSearch validation
# This script configures OpenSearch connection, runs the test, and validates results

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# OpenSearch configuration (set these or pass as environment variables)
OPENSEARCH_HOST="${OPENSEARCH_HOST:-localhost}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
OPENSEARCH_USER="${OPENSEARCH_USER:-admin}"
OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:-}"
USE_SSL="${USE_SSL:-true}"

# Default values
PROFILE="low_rate"
INDEX_PREFIX="fluentbit-bench"
VALIDATE=true
CLEANUP=false
USE_OPTIMIZED=false
USE_DATASTREAM=false
USE_DEBUG=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run a benchmark test with OpenSearch output and validate data integrity.

Options:
    -h, --host HOST           OpenSearch host (default: $OPENSEARCH_HOST)
    -p, --port PORT           OpenSearch port (default: $OPENSEARCH_PORT)
    -u, --user USER           OpenSearch username (optional, default: $OPENSEARCH_USER)
    -w, --password PASS       OpenSearch password (optional)
    --profile PROFILE         Test profile (default: $PROFILE)
    --index-prefix PREFIX     Index name prefix (default: $INDEX_PREFIX)
    --no-validate             Skip validation after test
    --cleanup                 Delete index after validation
    --no-ssl                  Disable SSL
    --optimized               Use optimized config (recommended for high-throughput)
    --datastream              Create index template with static mapping and data stream
    --debug                   Use debug config (generous timeouts + info logging)
    --help                    Show this help

Note: Authentication is optional. Leave user/password unset for instances without auth.

Environment Variables:
    OPENSEARCH_HOST, OPENSEARCH_PORT, OPENSEARCH_USER, OPENSEARCH_PASSWORD, USE_SSL

Examples:
    # Run without authentication
    export OPENSEARCH_HOST="opensearch.example.com"
    $0 --profile medium_rate --no-ssl

    # Run with credentials from environment
    export OPENSEARCH_HOST="opensearch.example.com"
    export OPENSEARCH_USER="admin"
    export OPENSEARCH_PASSWORD="mypassword"
    $0 --profile medium_rate

    # Run with command line options
    $0 -h opensearch.example.com -u admin -w mypass --profile high_rate

    # Run and cleanup
    $0 --profile stress_test --cleanup
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            OPENSEARCH_HOST="$2"
            shift 2
            ;;
        -p|--port)
            OPENSEARCH_PORT="$2"
            shift 2
            ;;
        -u|--user)
            OPENSEARCH_USER="$2"
            shift 2
            ;;
        -w|--password)
            OPENSEARCH_PASSWORD="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --index-prefix)
            INDEX_PREFIX="$2"
            shift 2
            ;;
        --no-validate)
            VALIDATE=false
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --no-ssl)
            USE_SSL=false
            shift
            ;;
        --optimized)
            USE_OPTIMIZED=true
            shift
            ;;
        --datastream)
            USE_DATASTREAM=true
            shift
            ;;
        --debug)
            USE_DEBUG=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Note: Password is optional for instances without authentication
if [ ! -z "$OPENSEARCH_USER" ] && [ -z "$OPENSEARCH_PASSWORD" ]; then
    echo -e "${YELLOW}Warning: User set but password not provided${NC}"
fi

# Generate index name with timestamp and profile
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
INDEX_NAME="${INDEX_PREFIX}-${PROFILE}-${TIMESTAMP}"

echo -e "${BLUE}=== OpenSearch Benchmark Test ===${NC}"
echo "Profile: $PROFILE"
echo "OpenSearch: $OPENSEARCH_HOST:$OPENSEARCH_PORT"
echo "Index: $INDEX_NAME"
echo ""

# Export environment variables for fluent-bit config
export OPENSEARCH_HOST
export OPENSEARCH_PORT
export OPENSEARCH_INDEX="$INDEX_NAME"

# Determine TLS setting
if [ "$USE_SSL" = "true" ]; then
    export OPENSEARCH_TLS="On"
else
    export OPENSEARCH_TLS="Off"
fi

# Use appropriate config file based on authentication and optimization
if [ -z "$OPENSEARCH_USER" ] || [ -z "$OPENSEARCH_PASSWORD" ]; then
    if [ "$USE_DEBUG" = true ]; then
        echo "Using DEBUG config (generous timeouts + info logging) without authentication"
        FB_OPENSEARCH_CONF="configs/fluent-bit/fluent-bit-opensearch-noauth-optimized-debug.conf"
    elif [ "$USE_OPTIMIZED" = true ]; then
        echo "Using optimized OpenSearch config without authentication"
        FB_OPENSEARCH_CONF="configs/fluent-bit/fluent-bit-opensearch-noauth-optimized.conf"
    else
        echo "Using OpenSearch config without authentication"
        FB_OPENSEARCH_CONF="configs/fluent-bit/fluent-bit-opensearch-noauth.conf"
    fi
else
    export OPENSEARCH_USER
    export OPENSEARCH_PASSWORD
    if [ "$USE_OPTIMIZED" = true ]; then
        echo "Using optimized OpenSearch config with authentication"
        FB_OPENSEARCH_CONF="configs/fluent-bit/fluent-bit-opensearch-optimized.conf"
    else
        echo "Using OpenSearch config with authentication"
        FB_OPENSEARCH_CONF="configs/fluent-bit/fluent-bit-opensearch.conf"
    fi
fi

# Check if config file exists
if [ ! -f "configs/injector/profiles/${PROFILE}.conf" ]; then
    echo -e "${RED}Error: Profile 'configs/injector/profiles/${PROFILE}.conf' not found${NC}"
    exit 1
fi

# Read expected message count from profile
EXPECTED_COUNT=$(grep "^duration" "configs/injector/profiles/${PROFILE}.conf" | cut -d= -f2 | tr -d ' ')
TARGET_RATE=$(grep "^target_rate" "configs/injector/profiles/${PROFILE}.conf" | cut -d= -f2 | tr -d ' ')
EXPECTED_COUNT=$((EXPECTED_COUNT * TARGET_RATE))

echo "Expected messages: $EXPECTED_COUNT"
echo ""

# Helper: build a curl command with optional auth and SSL
os_curl() {
    local METHOD="$1"
    local PATH_URL="$2"
    local DATA="$3"

    PROTOCOL="https"
    if [ "$USE_SSL" = "false" ]; then
        PROTOCOL="http"
    fi

    CURL_ARGS="curl -sk -X $METHOD"
    if [ ! -z "$OPENSEARCH_USER" ] && [ ! -z "$OPENSEARCH_PASSWORD" ]; then
        CURL_ARGS="$CURL_ARGS -u '${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}'"
    fi
    CURL_ARGS="$CURL_ARGS -H 'Content-Type: application/json'"
    if [ ! -z "$DATA" ]; then
        CURL_ARGS="$CURL_ARGS -d '$DATA'"
    fi
    CURL_ARGS="$CURL_ARGS '${PROTOCOL}://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}${PATH_URL}'"

    eval "$CURL_ARGS"
}

# Set up data stream with index template and static mapping
if [ "$USE_DATASTREAM" = true ]; then
    # Data stream name (no timestamp — the data stream manages backing indices)
    DS_NAME="${INDEX_PREFIX}-${PROFILE}"
    TEMPLATE_NAME="${INDEX_PREFIX}-template"

    # Override index name for fluent-bit to target the data stream
    INDEX_NAME="$DS_NAME"
    export OPENSEARCH_INDEX="$INDEX_NAME"

    echo -e "${YELLOW}Setting up data stream with static mapping...${NC}"
    echo "Template: $TEMPLATE_NAME"
    echo "Data stream: $DS_NAME"
    echo ""

    # Delete existing data stream and template if present (start clean)
    echo "Cleaning up any existing data stream and template..."
    os_curl DELETE "/_data_stream/${DS_NAME}" > /dev/null 2>&1 || true
    os_curl DELETE "/_index_template/${TEMPLATE_NAME}" > /dev/null 2>&1 || true

    # Create index template with static mapping and data stream enabled
    TEMPLATE_BODY=$(cat <<'TEMPLATE_EOF'
{
  "index_patterns": ["INDEX_PATTERN_PLACEHOLDER"],
  "data_stream": {},
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "refresh_interval": "10s",
      "index.translog.durability": "async",
      "index.translog.sync_interval": "10s"
    },
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "pri":        { "type": "keyword" },
        "host":       { "type": "keyword" },
        "ident":      { "type": "keyword" },
        "pid":        { "type": "keyword" },
        "msgid":      { "type": "keyword" },
        "extradata":  { "type": "keyword" },
        "message":    { "type": "text", "norms": false }
      }
    }
  }
}
TEMPLATE_EOF
)
    # Replace placeholder with actual index pattern
    TEMPLATE_BODY="${TEMPLATE_BODY//INDEX_PATTERN_PLACEHOLDER/${DS_NAME}}"

    echo "Creating index template..."
    TEMPLATE_RESULT=$(os_curl PUT "/_index_template/${TEMPLATE_NAME}" "$TEMPLATE_BODY")
    if echo "$TEMPLATE_RESULT" | grep -q '"acknowledged":true'; then
        echo -e "${GREEN}✓ Index template created${NC}"
    else
        echo -e "${RED}✗ Failed to create index template:${NC}"
        echo "$TEMPLATE_RESULT"
        exit 1
    fi

    # Create the data stream
    echo "Creating data stream..."
    DS_RESULT=$(os_curl PUT "/_data_stream/${DS_NAME}" "")
    if echo "$DS_RESULT" | grep -q '"acknowledged":true'; then
        echo -e "${GREEN}✓ Data stream created${NC}"
    else
        echo -e "${RED}✗ Failed to create data stream:${NC}"
        echo "$DS_RESULT"
        exit 1
    fi

    echo ""
fi

# Create buffer directory if using optimized config (clean old data to avoid contaminating results)
if [ "$USE_OPTIMIZED" = true ]; then
    echo -e "${YELLOW}Cleaning and recreating buffer directory for optimized config...${NC}"
    rm -rf /tmp/fluentbit-buffer
    mkdir -p /tmp/fluentbit-buffer
    echo ""
fi

# Run the benchmark
echo -e "${YELLOW}Starting benchmark...${NC}"
./run_benchmark.sh -p "$PROFILE" -f "$FB_OPENSEARCH_CONF" -m

BENCH_EXIT=$?

if [ $BENCH_EXIT -ne 0 ]; then
    echo -e "${RED}Benchmark failed with exit code $BENCH_EXIT${NC}"
    exit $BENCH_EXIT
fi

echo ""
echo -e "${GREEN}Benchmark completed${NC}"
echo ""

# Show Fluent-Bit log summary when in debug mode
if [ "$USE_DEBUG" = true ]; then
    # Find the most recent FB log file
    FB_LOG=$(ls -t results/fluentbit_*.log 2>/dev/null | head -1)
    if [ -n "$FB_LOG" ] && [ -f "$FB_LOG" ]; then
        echo -e "${YELLOW}=== Fluent-Bit Log Summary (debug mode) ===${NC}"
        RETRY_LINES=$(grep -c -i "retry\|retries\|retrying" "$FB_LOG" 2>/dev/null || echo 0)
        TIMEOUT_LINES=$(grep -c -i "timeout\|timed out" "$FB_LOG" 2>/dev/null || echo 0)
        ERROR_LINES=$(grep -c -i "error\|failed\|broken" "$FB_LOG" 2>/dev/null || echo 0)

        echo "  Retry-related log lines:  $RETRY_LINES"
        echo "  Timeout-related log lines: $TIMEOUT_LINES"
        echo "  Error-related log lines:   $ERROR_LINES"
        echo ""

        if [ $TIMEOUT_LINES -gt 0 ]; then
            echo -e "${YELLOW}Sample timeout messages:${NC}"
            grep -i "timeout\|timed out" "$FB_LOG" | head -5
            echo ""
        fi

        if [ $RETRY_LINES -gt 0 ]; then
            echo -e "${YELLOW}Sample retry messages:${NC}"
            grep -i "retry\|retries\|retrying" "$FB_LOG" | head -5
            echo ""
        fi

        echo "Full log: $FB_LOG"
        echo ""
    fi
fi

# Validate if requested
if [ "$VALIDATE" = true ]; then
    echo -e "${YELLOW}=== Waiting for OpenSearch to index all documents ===${NC}"
    OS_POLL_INTERVAL=3
    OS_POLL_TIMEOUT=300
    OS_POLL_ELAPSED=0
    PREV_DOC_COUNT=0
    OS_STABLE_COUNT=0
    OS_STABLE_NEEDED=3  # 3 consecutive polls with no change = indexed
    INDEXING_START=$(date +%s%N)

    while [ $OS_POLL_ELAPSED -lt $OS_POLL_TIMEOUT ]; do
        # Query OpenSearch for document count
        DOC_COUNT_RESULT=$(os_curl GET "/${INDEX_NAME}/_count" '{"query":{"match_all":{}}}' 2>/dev/null || echo '{}')
        DOC_COUNT=$(echo "$DOC_COUNT_RESULT" | jq -r '.count // 0' 2>/dev/null || echo 0)

        DOC_DELTA=$((DOC_COUNT - PREV_DOC_COUNT))
        INDEX_RATE=$((DOC_DELTA / OS_POLL_INTERVAL))

        printf "\r  [%3ds] docs indexed: %d / %d  |  %d docs/s   " \
            $OS_POLL_ELAPSED $DOC_COUNT $EXPECTED_COUNT $INDEX_RATE

        # Check completion: all docs indexed and count stable
        if [ $DOC_COUNT -ge $EXPECTED_COUNT ]; then
            echo ""
            break
        fi

        # Detect stall
        if [ $DOC_DELTA -eq 0 ] && [ $DOC_COUNT -gt 0 ]; then
            OS_STABLE_COUNT=$((OS_STABLE_COUNT + 1))
        else
            OS_STABLE_COUNT=0
        fi

        if [ $OS_STABLE_COUNT -ge $OS_STABLE_NEEDED ] && [ $DOC_COUNT -gt 0 ]; then
            echo ""
            if [ $DOC_COUNT -lt $EXPECTED_COUNT ]; then
                echo -e "${YELLOW}Warning: indexing stalled at $DOC_COUNT / $EXPECTED_COUNT documents${NC}"
            fi
            break
        fi

        PREV_DOC_COUNT=$DOC_COUNT
        sleep $OS_POLL_INTERVAL
        OS_POLL_ELAPSED=$((OS_POLL_ELAPSED + OS_POLL_INTERVAL))
    done

    INDEXING_END=$(date +%s%N)
    INDEXING_DURATION_MS=$(( (INDEXING_END - INDEXING_START) / 1000000 ))
    INDEXING_DURATION_S=$(echo "scale=2; $INDEXING_DURATION_MS / 1000" | bc)
    echo -e "Indexing completed: ${GREEN}$DOC_COUNT${NC} documents in ${GREEN}${INDEXING_DURATION_S}s${NC}"
    echo ""

    echo -e "${YELLOW}Validating data integrity...${NC}"
    echo ""

    SSL_FLAG=""
    if [ "$USE_SSL" = "false" ]; then
        SSL_FLAG="--no-ssl"
    fi

    # Build validation command
    VAL_CMD="python3 validate_opensearch.py --host '$OPENSEARCH_HOST' --port $OPENSEARCH_PORT --index '$INDEX_NAME' --expected-count $EXPECTED_COUNT $SSL_FLAG"

    # Add credentials only if provided
    if [ ! -z "$OPENSEARCH_USER" ]; then
        VAL_CMD="$VAL_CMD --user '$OPENSEARCH_USER'"
    fi
    if [ ! -z "$OPENSEARCH_PASSWORD" ]; then
        VAL_CMD="$VAL_CMD --password '$OPENSEARCH_PASSWORD'"
    fi

    if eval "$VAL_CMD"; then

        echo ""
        echo -e "${GREEN}✓ Validation passed!${NC}"
        VALIDATION_PASSED=true
    else
        echo ""
        echo -e "${RED}✗ Validation failed!${NC}"
        VALIDATION_PASSED=false
    fi
fi

# Cleanup if requested
if [ "$CLEANUP" = true ]; then
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"

    if [ "$USE_DATASTREAM" = true ]; then
        # Delete data stream first, then template
        echo "Deleting data stream: $DS_NAME"
        os_curl DELETE "/_data_stream/${DS_NAME}" > /dev/null 2>&1 || true
        echo "Deleting index template: $TEMPLATE_NAME"
        os_curl DELETE "/_index_template/${TEMPLATE_NAME}" > /dev/null 2>&1 || true
        echo "Data stream and template deleted"
    else
        PROTOCOL="https"
        if [ "$USE_SSL" = "false" ]; then
            PROTOCOL="http"
        fi

        # Build curl command with optional auth
        CURL_CMD="curl -sk -X DELETE"
        if [ ! -z "$OPENSEARCH_USER" ] && [ ! -z "$OPENSEARCH_PASSWORD" ]; then
            CURL_CMD="$CURL_CMD -u '${OPENSEARCH_USER}:${OPENSEARCH_PASSWORD}'"
        fi
        CURL_CMD="$CURL_CMD '${PROTOCOL}://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/${INDEX_NAME}'"

        eval "$CURL_CMD" > /dev/null 2>&1
        echo "Index deleted"
    fi
fi

echo ""
echo -e "${BLUE}=== Test Complete ===${NC}"
echo "Index: $INDEX_NAME"

if [ "$VALIDATE" = true ] && [ "$VALIDATION_PASSED" = true ]; then
    exit 0
elif [ "$VALIDATE" = true ]; then
    exit 1
else
    exit 0
fi
