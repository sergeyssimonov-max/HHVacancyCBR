#!/bin/bash
set -euo pipefail
# Usage: bash scripts/benchmarks/build_filter_benchmarks.sh /absolute/scratch/output-binary [source-directory]
if [[ $# -lt 1 || $# -gt 2 || "$1" != /* || ! -d "$(dirname "$1")" ]]; then
    echo 'Pass an absolute output binary path in an existing scratch directory.' >&2
    exit 2
fi
benchmark_root="$(cd "$(dirname "$0")/../.." && pwd)"
# Only an omitted argument selects current sources; an empty baseline must fail.
benchmark_sources="${2-$benchmark_root/HHVacancyCBR/HHVacancyCBR}"
[[ -d "$benchmark_sources" ]] || { echo 'Source directory does not exist.' >&2; exit 2; }
clang -c "$benchmark_sources/Vendor/Streebog/Bridge.c" -o "$(dirname "$1")/streebog.o"
benchmark_inputs=()
while IFS= read -r benchmark_source; do
    benchmark_inputs+=("$benchmark_source")
done < <(python3 "$benchmark_root/scripts/swift_sources.py" "$benchmark_sources")
swiftc -import-objc-header "$benchmark_sources/Vendor/Streebog/Bridge.h" "$(dirname "$1")/streebog.o" -O -parse-as-library -module-cache-path "$(dirname "$1")/module-cache" \
    "${benchmark_inputs[@]}" \
    "$benchmark_root/scripts/benchmarks/FilterBenchmarks.swift" -o "$1"
