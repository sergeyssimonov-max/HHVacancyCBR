#!/usr/bin/env python3
"""Standalone harness inputs, including nested source folders; exclude SwiftUI launch/composition."""
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(__file__).resolve().parents[1] / "HHVacancyCBR/HHVacancyCBR"
for source in sorted(root.rglob("*.swift")):
    if source.name not in {"HHVacancyCBRApp.swift", "AppComposition.swift", "ContentView.swift"}:
        print(source)
