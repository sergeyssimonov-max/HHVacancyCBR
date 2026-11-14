import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import scripts.verify_independence as independence
import scripts.verify_project_sources as membership
from scripts.compare_test_inventory import inventory


class SourceVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "HHVacancyCBR"
        self.app = self.project / "HHVacancyCBR"
        self.nested = self.app / "Networking" / "Client.swift"
        self.nested.parent.mkdir(parents=True)
        self.nested.write_text("struct Client {}\n")
        self.objects = {
            "project": {"isa": "PBXProject", "mainGroup": "main"},
            "main": {"isa": "PBXGroup", "children": ["app"]},
            "app": {"isa": "PBXGroup", "path": "HHVacancyCBR", "children": ["networking"]},
            "networking": {"isa": "PBXGroup", "path": "Networking", "children": ["client"]},
            "client": {"isa": "PBXFileReference", "path": "Client.swift"},
            "clientBuild": {"isa": "PBXBuildFile", "fileRef": "client"},
            "sources": {"isa": "PBXSourcesBuildPhase", "files": ["clientBuild"]},
            "target": {"isa": "PBXNativeTarget", "name": "HHVacancyCBR", "buildPhases": ["sources"]},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def verify_membership(self):
        payload = json.dumps({"rootObject": "project", "objects": self.objects}).encode()
        with mock.patch.object(membership.subprocess, "check_output", return_value=payload), contextlib.redirect_stdout(io.StringIO()):
            membership.verify(self.project)

    def test_accepts_nested_source_with_exact_target_membership(self):
        self.verify_membership()

    def test_rejects_nested_source_missing_from_build_phase(self):
        self.objects["sources"]["files"] = []
        with self.assertRaisesRegex(AssertionError, "missing=.*Client.swift"):
            self.verify_membership()

    def test_rejects_duplicate_membership_even_with_distinct_build_ids(self):
        self.objects["duplicateBuild"] = {"isa": "PBXBuildFile", "fileRef": "client"}
        self.objects["sources"]["files"].append("duplicateBuild")
        with self.assertRaisesRegex(AssertionError, "duplicate source membership"):
            self.verify_membership()

    def test_rejects_production_source_assigned_to_test_target(self):
        self.objects["target"]["name"] = "HHVacancyCBRTests"
        with self.assertRaisesRegex(AssertionError, "unexpected=.*Client.swift"):
            self.verify_membership()

    def test_independence_scans_nested_swift_for_removed_feature(self):
        # Minimal valid repository fixture; the authorization value is synthetic.
        ids = ["47858", "1654251", "125886", "2608647", "9942121"]
        (self.app / "employers.json").write_text(json.dumps({"version": 2, "employers": [
            {"id": value, "name": value, "comment": "https://hh.ru/employer/" + value}
            for value in ids
        ]}))
        keys = ["bank_of_russia", "rosinkas", "nspk", "rnpk", "nsis", "uk_fkbs"]
        (self.app / "OrganizationRegistry.swift").write_text("\n".join(
            f'.init(id: "{key}", name: "fixture", hhEmployerIDs: [])' for key in keys))
        (self.app / "ApplicationSupportLocation.swift").write_text('static let directoryName = "HHVacancyCBR"')
        (self.app / "HHAuthConfig.swift").write_text('static let appAccessToken = "SYNTHETIC_TEST_VALUE"')
        project_file = self.project / "HHVacancyCBR.xcodeproj" / "project.pbxproj"
        project_file.parent.mkdir()
        project_file.write_text('PRODUCT_BUNDLE_IDENTIFIER = local.sergey.HHVacancyCBR;\npath = "ЦБВакансии.app";')
        with mock.patch.multiple(independence, ROOT=self.root, PROJECT=self.project, APP=self.app), contextlib.redirect_stdout(io.StringIO()):
            independence.main()
            self.nested.write_text("struct Favorites {}\n")
            with self.assertRaises(AssertionError) as failure:
                independence.main()
            self.assertIn("Networking/Client.swift", str(failure.exception))


class TestInventoryTests(unittest.TestCase):
    METHOD = "    @MainActor\n    func testExample() {\n        XCTAssertEqual(1, 1)\n    }\n"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.target = self.root / "HHVacancyCBR" / "HHVacancyCBRTests"
        self.target.mkdir(parents=True)
        self.original = self.target / "Cases.swift"
        self.original.write_text("final class Cases: XCTestCase {\n" + self.METHOD + "}\n")

    def tearDown(self):
        self.temporary.cleanup()

    def test_selector_and_body_survive_move_to_nested_extension(self):
        before = inventory(self.root)
        self.original.write_text("final class Cases: XCTestCase {}\n")
        nested = self.target / "Topic" / "TopicTests.swift"
        nested.parent.mkdir()
        nested.write_text("extension Cases {\n" + self.METHOD + "}\n")
        self.assertEqual(before, inventory(self.root))

    def test_assertion_or_actor_annotation_change_is_detected(self):
        before = inventory(self.root)
        for method in (self.METHOD.replace("Equal(1, 1)", "Equal(1, 2)"), self.METHOD.replace("    @MainActor\n", "")):
            with self.subTest(method=method):
                self.original.write_text("final class Cases: XCTestCase {\n" + method + "}\n")
                self.assertNotEqual(before, inventory(self.root))

    def test_duplicate_selector_is_rejected_across_files(self):
        (self.target / "Duplicate.swift").write_text("extension Cases {\n" + self.METHOD + "}\n")
        with self.assertRaisesRegex(AssertionError, "Duplicate test selector"):
            inventory(self.root)


if __name__ == "__main__":
    unittest.main()
