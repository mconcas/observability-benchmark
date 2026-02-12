#!/bin/bash
# Analyze Fluent-bit logs for data loss indicators
# Usage: ./analyze_fluentbit_logs.sh <path-to-fluent-bit-log>

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <fluent-bit-log-file>"
    echo ""
    echo "Example:"
    echo "  $0 results/fluentbit_20260212_181451.log"
    exit 1
fi

LOGFILE="$1"

if [ ! -f "$LOGFILE" ]; then
    echo "Error: File not found: $LOGFILE"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Fluent-bit Log Analysis - Data Loss Detection${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Analyzing: $LOGFILE"
echo ""

# Count various error types
CONFIG_ERRORS=$(grep "invalid retry_limit" "$LOGFILE" 2>/dev/null | wc -l)
BUFFER_ERRORS=$(grep "cannot increase buffer" "$LOGFILE" 2>/dev/null | wc -l)
RETRY_FAILURES=$(grep "failed to flush chunk" "$LOGFILE" 2>/dev/null | wc -l)
PERMANENT_LOSSES=$(grep "cannot be retried" "$LOGFILE" 2>/dev/null | wc -l)
HTTP_ERRORS=$(grep "http_do=-1" "$LOGFILE" 2>/dev/null | wc -l)

# Calculate severity
TOTAL_ISSUES=$((CONFIG_ERRORS + BUFFER_ERRORS + PERMANENT_LOSSES))

echo -e "${BLUE}━━━ Configuration Issues ━━━${NC}"
if [ $CONFIG_ERRORS -gt 0 ]; then
    echo -e "${RED}✗ Invalid retry_limit config: $CONFIG_ERRORS occurrences${NC}"
    echo "  Fix: Change 'Retry_Limit False' to 'Retry_Limit 10000'"
else
    echo -e "${GREEN}✓ No configuration errors detected${NC}"
fi
echo ""

echo -e "${BLUE}━━━ Buffer Size Issues ━━━${NC}"
if [ $BUFFER_ERRORS -gt 0 ]; then
    echo -e "${RED}✗ Buffer size errors: $BUFFER_ERRORS occurrences${NC}"
    echo "  Bulk responses exceeded buffer capacity"
    echo "  Fix: Increase 'Buffer_Size' to 256KB or higher"
    echo ""
    echo "  Sample errors:"
    grep "cannot increase buffer" "$LOGFILE" | head -3 | sed 's/^/    /'
else
    echo -e "${GREEN}✓ No buffer size errors${NC}"
fi
echo ""

echo -e "${BLUE}━━━ Retry Activity ━━━${NC}"
if [ $RETRY_FAILURES -gt 0 ]; then
    if [ $RETRY_FAILURES -gt 100 ]; then
        echo -e "${RED}✗ High retry count: $RETRY_FAILURES retries${NC}"
        echo "  Indicates sustained backpressure from OpenSearch"
    else
        echo -e "${YELLOW}⚠ Moderate retry count: $RETRY_FAILURES retries${NC}"
        echo "  Some temporary failures occurred (normal in high-load scenarios)"
    fi
else
    echo -e "${GREEN}✓ No retries needed (perfect run)${NC}"
fi
echo ""

echo -e "${BLUE}━━━ PERMANENT DATA LOSS ━━━${NC}"
if [ $PERMANENT_LOSSES -gt 0 ]; then
    echo -e "${RED}✗✗✗ CRITICAL: $PERMANENT_LOSSES chunks permanently lost! ✗✗✗${NC}"
    echo ""
    echo "  Each lost chunk contains multiple messages (potentially thousands)"
    echo "  This explains the gaps and missing data in validation results"
    echo ""
    echo "  Lost chunks:"
    grep "cannot be retried" "$LOGFILE" | sed 's/^/    /' | head -10
    if [ $PERMANENT_LOSSES -gt 10 ]; then
        echo "    ... and $((PERMANENT_LOSSES - 10)) more"
    fi
else
    echo -e "${GREEN}✓ No permanent data loss detected${NC}"
fi
echo ""

echo -e "${BLUE}━━━ HTTP Failures ━━━${NC}"
echo "  Total HTTP errors: $HTTP_ERRORS"
if [ $HTTP_ERRORS -gt 0 ]; then
    echo "  (These triggered retries, some may have succeeded later)"
fi
echo ""

# Overall assessment
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   OVERALL ASSESSMENT${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ $PERMANENT_LOSSES -gt 0 ]; then
    echo -e "${RED}STATUS: CRITICAL DATA LOSS${NC}"
    echo ""
    echo "Impact:"
    echo "  • $PERMANENT_LOSSES chunks permanently lost"
    echo "  • Validation will show gaps and count mismatches"
    echo "  • Expect <50% data delivery rate"
    echo ""
    echo "Root Causes:"
    [ $CONFIG_ERRORS -gt 0 ] && echo "  • Invalid retry configuration (falling back to default limit)"
    [ $BUFFER_ERRORS -gt 0 ] && echo "  • Response buffer too small (causing failures)"
    echo ""
    echo "Required Actions:"
    echo "  1. Use optimized config: --optimized flag"
    echo "  2. Fix Retry_Limit: use numeric value (10000)"
    echo "  3. Increase Buffer_Size: 256KB minimum"
    echo "  4. Enable filesystem buffering for backpressure handling"
elif [ $BUFFER_ERRORS -gt 0 ] || [ $CONFIG_ERRORS -gt 0 ]; then
    echo -e "${YELLOW}STATUS: AT RISK${NC}"
    echo ""
    echo "Configuration issues detected that will lead to data loss"
    echo "under sustained load."
    echo ""
    echo "Required Actions:"
    [ $CONFIG_ERRORS -gt 0 ] && echo "  • Fix Retry_Limit configuration (use numeric value)"
    [ $BUFFER_ERRORS -gt 0 ] && echo "  • Increase Buffer_Size to 256KB"
elif [ $RETRY_FAILURES -gt 100 ]; then
    echo -e "${YELLOW}STATUS: BACKPRESSURE${NC}"
    echo ""
    echo "OpenSearch experiencing backpressure but handling it."
    echo "No data loss yet, but at risk under higher load."
    echo ""
    echo "Recommendations:"
    echo "  • Monitor OpenSearch write queue and rejections"
    echo "  • Consider optimized config for higher rates"
    echo "  • Ensure filesystem buffering enabled"
else
    echo -e "${GREEN}STATUS: HEALTHY${NC}"
    echo ""
    echo "No critical issues detected in Fluent-bit logs."
    echo ""
    if [ $RETRY_FAILURES -gt 0 ]; then
        echo "Minor retry activity is normal and was handled successfully."
    else
        echo "Perfect run with no retries needed."
    fi
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
