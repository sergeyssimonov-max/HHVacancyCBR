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
swiftc -import-objc-header "$benchmark_sources/Vendor/Streebog/Bridge.h" "$(dirname "$1")/streebog.o" -O -parse-as-library -module-cache-path "$(dirname "$1")/module-cache" \
    "$benchmark_sources/HHModels.swift" "$benchmark_sources/HHAPIClient.swift" \
    "$benchmark_sources/HHAuthConfig.swift" "$benchmark_sources/AreaDirectoryStore.swift" \
    "$benchmark_sources/VacancySnapshotStore.swift" "$benchmark_sources/ApplicationSupportLocation.swift" "$benchmark_sources/EmployerConfiguration.swift" \
    "$benchmark_sources/VacanciesPDFExporter.swift" "$benchmark_sources/PDFSourceEvidence.swift" "$benchmark_sources/OrganizationRegistry.swift" "$benchmark_sources/TrudvsemModels.swift" "$benchmark_sources/TrudvsemAPIClient.swift" "$benchmark_sources/TrudvsemViewModel.swift" "$benchmark_sources/TrudvsemPDFFormatter.swift" \
    "$benchmark_sources/VacancyCollectionService.swift" "$benchmark_sources/VacancySearchViewModel.swift" \
    "$benchmark_root/scripts/benchmarks/RuntimeBenchmarks.swift" -o "$1"
