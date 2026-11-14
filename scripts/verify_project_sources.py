#!/usr/bin/env python3
"""Verify recursive Swift/C discovery against exact Xcode target membership (macOS)."""
from collections import Counter
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'HHVacancyCBR'


def verify(project=PROJECT):
    data = json.loads(subprocess.check_output([
        'plutil', '-convert', 'json', '-o', '-',
        str(project / 'HHVacancyCBR.xcodeproj/project.pbxproj')]))
    objects = data['objects']
    paths = {}

    def visit(identifier, parent):
        obj = objects[identifier]
        path = parent / obj.get('path', '')
        if obj['isa'] == 'PBXGroup':
            for child in obj.get('children', []):
                visit(child, path)
        elif obj['isa'] == 'PBXFileReference':
            paths[identifier] = path

    visit(objects[data['rootObject']]['mainGroup'], project)
    for target in objects.values():
        if target['isa'] != 'PBXNativeTarget':
            continue
        name = target['name']
        if name not in ('HHVacancyCBR', 'HHVacancyCBRTests', 'HHVacancyCBRUITests'):
            continue
        expected = {p.resolve() for p in (project / name).rglob('*')
                    if p.suffix in ('.swift', '.c')}
        actual = []
        for phase_id in target['buildPhases']:
            phase = objects[phase_id]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                for build_id in phase['files']:
                    actual.append(paths[objects[build_id]['fileRef']].resolve())
        counts = Counter(actual)
        duplicates = [str(p.relative_to(project)) for p, count in counts.items() if count != 1]
        assert not duplicates, f'{name}: duplicate source membership: {duplicates}'
        # Streebog core is included by Bridge.c, never compiled a second time.
        expected.discard((project / 'HHVacancyCBR/Vendor/Streebog/gost3411-2012-core.c').resolve())
        assert set(actual) == expected, f'{name}: missing={expected-set(actual)}, unexpected={set(actual)-expected}'
        assert all(p.is_file() for p in actual), f'{name}: missing source on disk'
        print(f'{name}: {len(actual)} sources, exact target membership OK')


if __name__ == '__main__':
    verify()
