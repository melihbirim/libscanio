import unittest
from check_release import check


class ReleaseVersionTests(unittest.TestCase):
    def package(self, version="0.1.1"):
        return {"name": "libscanio", "version": version}

    def test_valid_release(self):
        self.assertEqual(check(self.package(), self.package(), "v0.1.1"), "0.1.1")

    def test_pr_without_tag(self):
        self.assertEqual(check(self.package(), self.package()), "0.1.1")

    def test_mismatched_version(self):
        with self.assertRaises(ValueError):
            check(self.package(), self.package("0.1.0"), "v0.1.1")

    def test_wrong_tag(self):
        for tag in ("v0.1.0", "0.1.1", "v0.1.1; echo unexpected"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                check(self.package(), self.package(), tag)

    def test_nonstable_versions(self):
        for version in ("0.1.1rc1", "0.1.1-beta.1", "01.1.1", "1.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                check(self.package(version), self.package(version))

    def test_wrong_name(self):
        with self.assertRaises(ValueError):
            check({"name": "other", "version": "0.1.1"}, self.package())


if __name__ == "__main__":
    unittest.main()
