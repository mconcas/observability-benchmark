#!/usr/bin/env python3
"""
Compare multiple benchmark results and generate a summary report
"""

import json
import os
import sys
import re
from pathlib import Path
from datetime import datetime

def parse_result_file(filepath):
    """Parse a benchmark result file and extract metrics"""
    metrics = {
        'timestamp': None,
        'config': None,
        'elapsed': 0,
        'messages': 0,
        'rate': 0,
        'throughput': 0,
        'errors': 0
    }

    with open(filepath, 'r') as f:
        content = f.read()

        # Extract timestamp
        ts_match = re.search(r'Timestamp: (\d{8}_\d{6})', content)
        if ts_match:
            metrics['timestamp'] = ts_match.group(1)

        # Extract config
        cfg_match = re.search(r'Injector Config: (.+)', content)
        if cfg_match:
            metrics['config'] = cfg_match.group(1)

        # Extract final statistics
        stats_match = re.search(
            r'Elapsed: ([\d.]+)s.*?Messages: (\d+).*?Rate: ([\d.]+) msg/s.*?Throughput: ([\d.]+) KB/s.*?Errors: (\d+)',
            content,
            re.DOTALL
        )

        if stats_match:
            metrics['elapsed'] = float(stats_match.group(1))
            metrics['messages'] = int(stats_match.group(2))
            metrics['rate'] = float(stats_match.group(3))
            metrics['throughput'] = float(stats_match.group(4))
            metrics['errors'] = int(stats_match.group(5))

    return metrics

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 compare_results.py <results_directory>")
        sys.exit(1)

    results_dir = Path(sys.argv[1])

    if not results_dir.exists():
        print(f"Error: Directory '{results_dir}' not found")
        sys.exit(1)

    # Find all benchmark result files
    result_files = sorted(results_dir.glob("benchmark_*.txt"))

    if not result_files:
        print(f"No benchmark result files found in '{results_dir}'")
        sys.exit(1)

    print("=== Fluent-Bit Benchmark Comparison ===")
    print()

    # Parse all results
    results = []
    for rf in result_files:
        metrics = parse_result_file(rf)
        if metrics['messages'] > 0:  # Only include valid results
            results.append(metrics)

    if not results:
        print("No valid results found")
        sys.exit(1)

    # Print comparison table
    print(f"{'Timestamp':<15} {'Config':<30} {'Messages':>12} {'Rate (msg/s)':>15} {'Throughput (KB/s)':>20} {'Errors':>8}")
    print("-" * 110)

    for r in results:
        config_name = Path(r['config']).stem if r['config'] else 'unknown'
        print(f"{r['timestamp']:<15} {config_name:<30} {r['messages']:>12,} {r['rate']:>15,.2f} {r['throughput']:>20,.2f} {r['errors']:>8}")

    print()
    print("=== Summary Statistics ===")

    max_rate = max(results, key=lambda x: x['rate'])
    max_throughput = max(results, key=lambda x: x['throughput'])
    total_messages = sum(r['messages'] for r in results)
    total_errors = sum(r['errors'] for r in results)

    print(f"Total messages sent: {total_messages:,}")
    print(f"Total errors: {total_errors:,}")
    print(f"Highest message rate: {max_rate['rate']:,.2f} msg/s ({Path(max_rate['config']).stem})")
    print(f"Highest throughput: {max_throughput['throughput']:,.2f} KB/s ({Path(max_throughput['config']).stem})")
    print(f"Average rate across tests: {sum(r['rate'] for r in results) / len(results):,.2f} msg/s")

if __name__ == '__main__':
    main()
