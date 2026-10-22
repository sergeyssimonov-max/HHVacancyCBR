#!/usr/bin/env python3
"""Bounded, read-only employer discovery. Candidates are never auto-approved."""
import json
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
QUERIES = ("УК ФКБС", "Управляющая компания Фонда консолидации банковского сектора")


def main():
    config = (ROOT / "HHVacancyCBR/HHVacancyCBR/HHAuthConfig.swift").read_text()
    match = re.search(r'appAccessToken = "([^\"]+)"', config)
    if not match:
        raise SystemExit("Application token configuration is unavailable")
    headers = {"Authorization": "Bearer " + match.group(1),
               "User-Agent": "HHVacancyCBR/1.0 (sergeyssimonov-max@users.noreply.github.com)"}

    def get(path):
        request = urllib.request.Request("https://api.hh.ru" + path, headers=headers)
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)

    candidates = {}
    for query in QUERIES:
        response = get("/employers?" + urllib.parse.urlencode({"text": query, "per_page": 20, "page": 0}))
        for item in response.get("items", []):
            identifier = item.get("id", "")
            if identifier.isascii() and identifier.isdecimal():
                candidates[identifier] = item.get("name")
    details = []
    for identifier in sorted(candidates)[:5]:
        value = get("/employers/" + identifier)
        details.append({key: value.get(key) for key in ("id", "name", "site_url", "description", "alternate_url")})
    print(json.dumps({"status": "candidates_only", "required_inn": "7714997584", "required_ogrn": "1177746688130",
                      "candidates": details, "configuration_changed": False}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"hh.ru HTTP {error.code}; no configuration was changed") from None
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit("Network request failed; no configuration was changed") from None
