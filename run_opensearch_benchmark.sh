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
    if [ "$USE_OPTIMIZED" = true ]; then
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

# Create buffer directory if using optimized config
if [ "$USE_OPTIMIZED" = true ]; then
    echo -e "${YELLOW}Creating buffer directory for optimized config...${NC}"
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

# Validate if requested
if [ "$VALIDATE" = true ]; then
    echo -e "${YELLOW}Waiting 15 seconds for OpenSearch to index all documents...${NC}"
    sleep 15

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
    echo -e "${YELLOW}Cleaning up index...${NC}"

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
