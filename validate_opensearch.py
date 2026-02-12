#!/usr/bin/env python3
"""
Validate data integrity by querying OpenSearch and checking for gaps/missing messages
"""

import argparse
import json
import sys
import re
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import ssl

def query_opensearch(host, port, index, user, password, query, use_ssl=True, scroll=None, is_scroll_request=False):
    """Query OpenSearch API"""
    protocol = "https" if use_ssl else "http"

    if is_scroll_request:
        # Scroll continuation request
        url = f"{protocol}://{host}:{port}/_search/scroll"
        query_body = {
            "scroll": scroll,
            "scroll_id": query  # query contains the scroll_id
        }
    else:
        # Regular search request
        if scroll:
            # Initial search with scroll - pass scroll as URL parameter
            url = f"{protocol}://{host}:{port}/{index}/_search?scroll={scroll}"
        else:
            url = f"{protocol}://{host}:{port}/{index}/_search"
        query_body = query

    headers = {
        'Content-Type': 'application/json',
    }

    # Create auth header
    if user and password:
        import base64
        credentials = base64.b64encode(f"{user}:{password}".encode()).decode()
        headers['Authorization'] = f'Basic {credentials}'

    # Create SSL context that doesn't verify certificates
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    req = Request(url, data=json.dumps(query_body).encode(), headers=headers, method='POST')

    try:
        with urlopen(req, context=ctx, timeout=30) as response:
            return json.loads(response.read().decode())
    except HTTPError as e:
        print(f"HTTP Error: {e.code} - {e.reason}")
        print(e.read().decode())
        sys.exit(1)
    except URLError as e:
        print(f"URL Error: {e.reason}")
        sys.exit(1)

def clear_scroll(host, port, scroll_id, user, password, use_ssl=True):
    """Clear scroll context"""
    protocol = "https" if use_ssl else "http"
    url = f"{protocol}://{host}:{port}/_search/scroll"

    headers = {
        'Content-Type': 'application/json',
    }

    if user and password:
        import base64
        credentials = base64.b64encode(f"{user}:{password}".encode()).decode()
        headers['Authorization'] = f'Basic {credentials}'

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    body = {"scroll_id": scroll_id}
    req = Request(url, data=json.dumps(body).encode(), headers=headers, method='DELETE')

    try:
        with urlopen(req, context=ctx, timeout=10) as response:
            pass
    except:
        pass  # Ignore errors during cleanup

def get_total_count(host, port, index, user, password, use_ssl=True):
    """Get total document count in index"""
    query = {
        "query": {"match_all": {}},
        "size": 0,
        "track_total_hits": True
    }

    result = query_opensearch(host, port, index, user, password, query, use_ssl)
    return result['hits']['total']['value']

def get_message_counters(host, port, index, user, password, use_ssl=True):
    """Extract all message counters from the index using scroll API"""
    counters = []

    # Initial query with scroll (scroll parameter will be in URL)
    query = {
        "query": {"match_all": {}},
        "size": 10000,  # Batch size per scroll request
        "sort": [{"@timestamp": "asc"}, {"_id": "asc"}],  # Stable sort with _id as tiebreaker
        "_source": ["message"]
    }

    # Initial search request with scroll
    result = query_opensearch(host, port, index, user, password, query, use_ssl, scroll="2m")
    scroll_id = result.get('_scroll_id')
    hits = result['hits']['hits']

    # Extract counters from first batch
    for hit in hits:
        source = hit['_source']
        message = source.get('message', '')

        # Extract counter from message like "Test message #123"
        match = re.search(r'Test message #(\d+)', message)
        if match:
            counters.append(int(match.group(1)))

    total_fetched = len(hits)
    batch_count = 1

    # Continue scrolling until no more results
    while len(hits) > 0:
        # Scroll to next batch
        result = query_opensearch(host, port, index, user, password, scroll_id, use_ssl,
                                  scroll="2m", is_scroll_request=True)
        scroll_id = result.get('_scroll_id')
        hits = result['hits']['hits']

        if len(hits) == 0:
            break

        batch_count += 1
        total_fetched += len(hits)

        # Extract counters from this batch
        for hit in hits:
            source = hit['_source']
            message = source.get('message', '')

            match = re.search(r'Test message #(\d+)', message)
            if match:
                counters.append(int(match.group(1)))

        # Print progress for large datasets
        if batch_count % 10 == 0:
            print(f"  Fetched {total_fetched:,} documents, extracted {len(counters):,} counters...", end='\r')

    # Clear scroll context
    if scroll_id:
        clear_scroll(host, port, scroll_id, user, password, use_ssl)

    if batch_count > 1:
        print(f"  Fetched {total_fetched:,} documents, extracted {len(counters):,} counters    ")

    return sorted(counters)

def validate_integrity(counters, expected_count=None):
    """Validate message sequence integrity"""
    results = {
        'total_messages': len(counters),
        'expected_count': expected_count,
        'count_match': False,
        'sequence_valid': True,
        'gaps': [],
        'duplicates': [],
        'first_counter': None,
        'last_counter': None,
    }

    if not counters:
        return results

    results['first_counter'] = counters[0]
    results['last_counter'] = counters[-1]

    # Check count
    if expected_count:
        results['count_match'] = (len(counters) == expected_count)

    # Check for gaps and duplicates
    prev = counters[0] - 1
    seen = set()

    for counter in counters:
        # Check for gaps
        if counter != prev + 1:
            gap_start = prev + 1
            gap_end = counter - 1
            results['gaps'].append((gap_start, gap_end))
            results['sequence_valid'] = False

        # Check for duplicates
        if counter in seen:
            results['duplicates'].append(counter)
            results['sequence_valid'] = False

        seen.add(counter)
        prev = counter

    return results

def main():
    parser = argparse.ArgumentParser(description='Validate Fluent-bit data integrity in OpenSearch')
    parser.add_argument('--host', required=True, help='OpenSearch host')
    parser.add_argument('--port', type=int, default=9200, help='OpenSearch port')
    parser.add_argument('--index', required=True, help='Index name to validate')
    parser.add_argument('--user', help='OpenSearch username')
    parser.add_argument('--password', help='OpenSearch password')
    parser.add_argument('--expected-count', type=int, help='Expected message count')
    parser.add_argument('--no-ssl', action='store_true', help='Disable SSL')
    parser.add_argument('--json', action='store_true', help='Output results as JSON')

    args = parser.parse_args()

    use_ssl = not args.no_ssl

    if not args.json:
        print(f"Validating data in OpenSearch index: {args.index}")
        print(f"Host: {args.host}:{args.port}")
        print()

    # Get total count
    total = get_total_count(args.host, args.port, args.index, args.user, args.password, use_ssl)

    if not args.json:
        print(f"Total documents in index: {total}")
        if args.expected_count:
            print(f"Expected count: {args.expected_count}")
        print()

    # Extract counters
    if not args.json:
        print("Extracting message counters...")

    counters = get_message_counters(args.host, args.port, args.index, args.user, args.password, use_ssl)

    # Validate
    results = validate_integrity(counters, args.expected_count)

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print()
        print("=== Validation Results ===")
        print(f"Messages found: {results['total_messages']}")

        if results['first_counter'] is not None:
            print(f"Counter range: {results['first_counter']} to {results['last_counter']}")

        if results['expected_count']:
            status = "✓ PASS" if results['count_match'] else "✗ FAIL"
            print(f"Count match: {status}")

        if results['sequence_valid']:
            print("Sequence integrity: ✓ PASS (no gaps or duplicates)")
        else:
            print("Sequence integrity: ✗ FAIL")

            if results['gaps']:
                print(f"\nGaps found ({len(results['gaps'])}): ")
                for gap_start, gap_end in results['gaps'][:10]:  # Show first 10
                    if gap_start == gap_end:
                        print(f"  - Missing: {gap_start}")
                    else:
                        print(f"  - Missing: {gap_start} to {gap_end}")
                if len(results['gaps']) > 10:
                    print(f"  ... and {len(results['gaps']) - 10} more")

            if results['duplicates']:
                print(f"\nDuplicates found ({len(results['duplicates'])}): ")
                for dup in results['duplicates'][:10]:  # Show first 10
                    print(f"  - {dup}")
                if len(results['duplicates']) > 10:
                    print(f"  ... and {len(results['duplicates']) - 10} more")

        print()

        # Exit with appropriate code
        if results['sequence_valid'] and (not results['expected_count'] or results['count_match']):
            print("✓ All validation checks passed!")
            sys.exit(0)
        else:
            print("✗ Validation failed!")
            sys.exit(1)

if __name__ == '__main__':
    main()
