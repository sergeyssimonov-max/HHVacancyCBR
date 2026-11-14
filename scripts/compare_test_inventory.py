#!/usr/bin/env python3
"""Compare XCTest selectors and verbatim test bodies across a mechanical file split.

This repository's test methods have one declaration per line at four-space
indentation. Fail closed if that convention changes; runtime XCTest discovery
must still be compared separately because this is a source preservation check.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def inventory(repository):
    result = {}
    for target in ("HHVacancyCBRTests", "HHVacancyCBRUITests"):
        folder = repository / "HHVacancyCBR" / target
        for path in sorted(folder.rglob("*.swift")):
            lines = path.read_text().splitlines(keepends=True)
            owner = None
            for index, line in enumerate(lines):
                declaration = re.match(r"^(?:final )?(?:class|extension) (\w+)", line)
                if declaration:
                    owner = declaration[1]
                method = re.match(r"^    func (test\w+)\(", line)
                if not method:
                    continue
                assert owner, f"Test outside a recognized XCTestCase: {path}:{index + 1}"
                start = index
                while start > 0 and lines[start - 1].startswith("    @"):
                    start -= 1
                end = next((j for j in range(index + 1, len(lines)) if lines[j].rstrip() == "    }"), None)
                assert end is not None, f"Unrecognized test method boundary: {path}:{index + 1}"
                identifier = f"{target}/{owner}/{method[1]}"
                assert identifier not in result, f"Duplicate test selector: {identifier}"
                body = "".join(lines[start:end + 1])
                result[identifier] = hashlib.sha256(body.encode()).hexdigest()
    assert result, f"No tests found in {repository}"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    before = inventory(args.before)
    after = inventory(args.after)
    report = {
        "beforeCount": len(before),
        "afterCount": len(after),
        "removed": sorted(before.keys() - after.keys()),
        "added": sorted(after.keys() - before.keys()),
        "changed": sorted(key for key in before.keys() & after.keys() if before[key] != after[key]),
    }
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return int(bool(report["removed"] or report["added"] or report["changed"]))


if __name__ == "__main__":
    raise SystemExit(main())
