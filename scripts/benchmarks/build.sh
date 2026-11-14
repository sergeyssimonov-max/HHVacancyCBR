#!/bin/bash
set -euo pipefail
# Usage: bash scripts/benchmarks/build.sh /absolute/scratch/output-binary
if [[ $# != 1 || "$1" != /* || ! -d "$(dirname "$1")" ]]; then
    echo 'Pass an absolute output binary path in an existing scratch directory.' >&2
    exit 2
fi
benchmark_root="$(cd "$(dirname "$0")/../.." && pwd)"
benchmark_sources="$benchmark_root/HHVacancyCBR/HHVacancyCBR"
clang -c "$benchmark_sources/Vendor/Streebog/Bridge.c" -o "$(dirname "$1")/streebog.o"
benchmark_inputs=()
while IFS= read -r benchmark_source; do
    benchmark_inputs+=("$benchmark_source")
done < <(python3 "$benchmark_root/scripts/swift_sources.py" "$benchmark_sources")
swiftc -import-objc-header "$benchmark_sources/Vendor/Streebog/Bridge.h" "$(dirname "$1")/streebog.o" -O -parse-as-library -module-cache-path "$(dirname "$1")/module-cache" \
    "${benchmark_inputs[@]}" \
    "$benchmark_root/scripts/benchmarks/ReliabilityChecks.swift" \
    "$benchmark_root/scripts/benchmarks/RuntimeBenchmarks.swift" -o "$1"
