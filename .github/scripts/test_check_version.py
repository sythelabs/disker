import plistlib
import unittest

from check_version import BundleVersion, parse_version, read_version, validate_versions


class VersionCheckTests(unittest.TestCase):
    def test_accepts_patch_minor_major_and_numeric_increases(self) -> None:
        for candidate in ("0.1.2", "0.2.0", "1.0.0", "0.1.10"):
            with self.subTest(candidate=candidate):
                proposed: BundleVersion = BundleVersion(candidate, 2)
                self.assertEqual(validate_versions(BundleVersion("0.1.1", 1), proposed), proposed)

    def test_rejects_unchanged_lower_and_stale_concurrent_versions(self) -> None:
        for current, candidate in (("0.1.1", "0.1.1"), ("0.1.1", "0.1.0"), ("0.2.0", "0.1.9"), ("0.1.2", "0.1.2")):
            with self.subTest(current=current, candidate=candidate):
                with self.assertRaisesRegex(ValueError, "Version must increase"):
                    validate_versions(BundleVersion(current, 1), BundleVersion(candidate, 2))

    def test_rejects_unchanged_and_lower_build_numbers(self) -> None:
        for build in (1, 2):
            with self.subTest(build=build):
                with self.assertRaisesRegex(ValueError, "Build number must increase"):
                    validate_versions(BundleVersion("0.1.0", 2), BundleVersion("0.1.1", build))

    def test_rejects_invalid_marketing_versions(self) -> None:
        for version in ("0.01.2", "v0.1.2", "0.1", "0.1.2-beta", "garbage"):
            with self.subTest(version=version):
                with self.assertRaises(ValueError):
                    parse_version(version)

    def test_reads_xml_and_binary_plists(self) -> None:
        for format in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(format=format):
                content: bytes = plistlib.dumps({"CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "12"}, fmt=format)
                self.assertEqual(read_version(content), BundleVersion("0.1.2", 12))

    def test_rejects_missing_and_invalid_metadata(self) -> None:
        for key, values in (
            ("CFBundleShortVersionString", (None, 1, "0.1", "0.01.2")),
            ("CFBundleVersion", (None, 2, "0", "-1", "01", "1.2", "garbage")),
        ):
            for value in values:
                with self.subTest(key=key, value=value):
                    metadata: dict[str, object] = {"CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "2"}
                    if value is None:
                        del metadata[key]
                    else:
                        metadata[key] = value
                    with self.assertRaises(ValueError):
                        read_version(plistlib.dumps(metadata))


if __name__ == "__main__":
    unittest.main()
