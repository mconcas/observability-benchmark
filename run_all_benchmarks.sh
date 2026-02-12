#!/bin/bash
# Run all benchmark profiles sequentially

set -e

PROFILES=("low_rate" "medium_rate" "high_rate" "stress_test")

echo "=== Running All Benchmark Profiles ==="
echo ""

for profile in "${PROFILES[@]}"; do
    echo "Running profile: $profile"
    ./run_benchmark.sh -p "$profile" -m
    echo ""
    echo "Waiting 5 seconds before next test..."
    sleep 5
done

echo "=== All benchmarks completed ==="
echo "Check the 'results' directory for outputs"
