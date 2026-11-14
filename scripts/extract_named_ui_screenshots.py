#!/usr/bin/env python3
"""Export named XCUITest PNGs and compare their original pixels without masks.

Requires Xcode's xcresulttool (Xcode 15 command syntax). Comparison uses Pillow
from the verification environment; it is not an application dependency.
Differences are reported, never normalized or accepted automatically.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def scalar(node, name, default=None):
    return node.get(name, {}).get("_value", default)


def result_object(bundle, identifier=None):
    arguments = ["xcrun", "xcresulttool", "get", "--path", str(bundle), "--format", "json"]
    if identifier:
        arguments.extend(["--id", identifier])
    return json.loads(subprocess.check_output(arguments))


def export(bundle, destination):
    # A separate directory preserves earlier evidence, even if names are reused.
    destination.mkdir(parents=True, exist_ok=False)
    records = []
    summaries = set()
    occurrences = Counter()
    for node in walk(result_object(bundle)):
        reference = node.get("testsRef", {}).get("id", {}).get("_value")
        if not reference:
            continue
        for test in walk(result_object(bundle, reference)):
            identifier = scalar(test, "identifier", "")
            summary = test.get("summaryRef", {}).get("id", {}).get("_value")
            ui_classes = ("HHVacancyCBRUITests/", "HHVacancyCBRUITestsLaunchTests/")
            if not identifier.startswith(ui_classes) or not summary or summary in summaries:
                continue
            summaries.add(summary)
            for attachment in walk(result_object(bundle, summary)):
                payload = attachment.get("payloadRef", {}).get("id", {}).get("_value")
                if not payload or scalar(attachment, "uniformTypeIdentifier") != "public.png":
                    continue
                name = scalar(attachment, "name", "unnamed")
                base_key = f"{identifier}/{name}"
                occurrences[base_key] += 1
                key = f"{base_key}/{occurrences[base_key]}"
                filename = hashlib.sha256(key.encode()).hexdigest()[:20] + ".png"
                path = destination / filename
                subprocess.run(["xcrun", "xcresulttool", "export", "--path", str(bundle),
                                "--id", payload, "--type", "file", "--output-path", str(path)], check=True)
                records.append({
                    "key": key, "test": identifier, "name": name,
                    "testStatus": scalar(test, "testStatus"),
                    "originalFilename": scalar(attachment, "filename"),
                    "filename": filename,
                    "fileSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                })
    assert records, "No named UI PNG attachments found"
    manifest = {"sourceBundle": str(bundle.resolve()), "screenshots": records}
    (destination / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"exported": len(records), "directory": str(destination.resolve())}, ensure_ascii=False))


def compare(before, after, output, diagnostic_frame_width=0):
    from PIL import Image, ImageChops

    def records(directory):
        rows = json.loads((directory / "manifest.json").read_text())["screenshots"]
        result = {row["key"]: row for row in rows}
        assert len(result) == len(rows), "Duplicate comparison key"
        return result

    left, right = records(before), records(after)
    report = {"missingAfter": sorted(left.keys() - right.keys()),
              "addedAfter": sorted(right.keys() - left.keys()), "comparisons": []}
    for key in sorted(left.keys() & right.keys()):
        with Image.open(before / left[key]["filename"]) as first, Image.open(after / right[key]["filename"]) as second:
            a, b = first.convert("RGBA"), second.convert("RGBA")
            row = {"key": key, "beforeSize": list(a.size), "afterSize": list(b.size),
                   "beforePixelSHA256": hashlib.sha256(a.tobytes()).hexdigest(),
                   "afterPixelSHA256": hashlib.sha256(b.tobytes()).hexdigest()}
            row["identicalPixels"] = a.size == b.size and row["beforePixelSHA256"] == row["afterPixelSHA256"]
            if a.size == b.size and not row["identicalPixels"]:
                difference = ImageChops.difference(a, b)
                channels = difference.split()
                maximum = channels[0]
                for channel in channels[1:]:
                    maximum = ImageChops.lighter(maximum, channel)
                histogram = maximum.histogram()
                row["differentPixels"] = sum(histogram[1:])
                row["differentFraction"] = row["differentPixels"] / (a.width * a.height)
                row["differenceBounds"] = list(maximum.getbbox())
                if diagnostic_frame_width:
                    frame = diagnostic_frame_width
                    if frame < 0 or frame * 2 >= min(a.size):
                        raise ValueError("Diagnostic frame width must leave a nonempty interior")
                    interior = maximum.crop((frame, frame, a.width - frame, a.height - frame))
                    interior_count = sum(interior.histogram()[1:])
                    bounds = interior.getbbox()
                    row["frameDiagnostic"] = {
                        "width": frame,
                        "differentPixelsWithinFrame": row["differentPixels"] - interior_count,
                        "differentPixelsElsewhere": interior_count,
                        "elsewhereDifferenceBounds": [part + frame for part in bounds] if bounds else None,
                    }
            report["comparisons"].append(row)
    report["identical"] = sum(row["identicalPixels"] for row in report["comparisons"])
    report["different"] = len(report["comparisons"]) - report["identical"]
    # No clocks, timestamps, spinners, UUIDs or content regions are masked.
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({name: report[name] for name in ["identical", "different", "missingAfter", "addedAfter"]}, ensure_ascii=False))
    return int(bool(report["different"] or report["missingAfter"] or report["addedAfter"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    exporter = commands.add_parser("export")
    exporter.add_argument("bundle", type=Path)
    exporter.add_argument("destination", type=Path)
    comparator = commands.add_parser("compare")
    comparator.add_argument("before", type=Path)
    comparator.add_argument("after", type=Path)
    comparator.add_argument("output", type=Path)
    comparator.add_argument("--diagnostic-frame-width", type=int, default=0,
                            help="Classify differences near the window frame; never changes raw equality or exit status")
    args = parser.parse_args()
    if args.command == "export":
        export(args.bundle, args.destination)
        return 0
    return compare(args.before, args.after, args.output, args.diagnostic_frame_width)


if __name__ == "__main__":
    raise SystemExit(main())
