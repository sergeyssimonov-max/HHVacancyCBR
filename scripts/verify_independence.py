#!/usr/bin/env python3
"""Check the standalone product without access to the source repository."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'HHVacancyCBR'
APP = PROJECT / 'HHVacancyCBR'


def main():
    forbidden = ('HHVacancy' + 'Sber', 'HHVACANCY' + 'SBER', 'Сбер' + 'Вакансии',
                 'HHVacancy' + 'Desk')
    for path in PROJECT.rglob('*'):
        assert not path.is_symlink(), f'Symlink in project: {path.relative_to(ROOT)}'
        if not path.is_file() or path.suffix == '.png' or 'xcuserdata' in path.parts:
            continue
        content = path.read_text(encoding='utf-8')
        assert not any(value in content or value in str(path.relative_to(ROOT)) for value in forbidden), path
        assert '/Users/' not in content, f'Absolute local dependency: {path}'
    assert not (ROOT / '.gitmodules').exists(), 'Submodules are not allowed'
    assert not (ROOT / '.git/objects/info/alternates').exists(), 'Shared Git object storage is not allowed'
    assert not list(APP.glob('employers.legacy-*.json')), 'Legacy employer lists must not ship'
    data = json.loads((APP / 'employers.json').read_text())
    assert data['version'] == 1
    ids = [entry['id'] for entry in data['employers']]
    assert set(ids) == {'47858', '1654251', '125886', '2608647'}, 'Review and document registry changes'
    assert len(ids) == len(set(ids))
    for entry in data['employers']:
        assert entry['name'].strip() and entry['comment'].strip()
        assert f'https://hh.ru/employer/{entry["id"]}' in entry['comment']
    project = (PROJECT / 'HHVacancyCBR.xcodeproj/project.pbxproj').read_text()
    assert 'PRODUCT_BUNDLE_IDENTIFIER = local.sergey.HHVacancyCBR;' in project
    assert 'path = "ЦБВакансии.app";' in project
    assert 'employers.legacy-' not in project
    assert 'static let directoryName = "HHVacancyCBR"' in (APP / 'ApplicationSupportLocation.swift').read_text()
    auth = (APP / 'HHAuthConfig.swift').read_text()
    token = re.search(r'static let appAccessToken = "([^"]+)"', auth)
    assert token and token.group(1) != 'REPLACE_WITH_YOUR_HH_APPLICATION_TOKEN', 'Application token is not configured'
    # Never print credentials; the user requested the existing embedded-token model.
    print('Independent identity, local sources, CBR registry, storage and authorization: OK')


if __name__ == '__main__':
    main()
