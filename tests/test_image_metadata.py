"""发布权限与镜像标签规则的离线回归测试。"""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("image_metadata", ROOT / "scripts/image_metadata.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MetadataTests(unittest.TestCase):
    def result(self, event="push", ref="refs/heads/main", changed=None, source=None):
        return module.metadata(source or (ROOT / "Containerfile").read_text(),
                               event, ref, "a" * 40, "Example/Repo", changed)

    def test_main_always_builds_and_publishes(self):
        for changed in (None, [], ["README.md"], ["Containerfile"]):
            result = self.result(changed=changed)
            self.assertEqual((result["build"], result["publish"]), ("true", "true"))
            self.assertEqual(result["image"], "ghcr.io/example/repo")
            self.assertRegex(result["image_tag"], r"^dsh-v.+-aaaaaaa$")

    def test_pr_docs_only(self):
        result = self.result("pull_request", "refs/pull/1/merge", ["docs/build.md", "LICENSE"])
        self.assertEqual((result["build"], result["publish"]), ("false", "false"))

    def test_pr_unknown_or_code_builds_without_publish(self):
        for changed in (None, [], ["README.md", "Containerfile"]):
            result = self.result("pull_request", "refs/pull/1/merge", changed)
            self.assertEqual((result["build"], result["publish"]), ("true", "false"))

    def test_dispatch_and_tags_never_publish(self):
        for event, ref in (("workflow_dispatch", "refs/heads/main"), ("push", "refs/tags/dsh-v1.0")):
            self.assertEqual(self.result(event, ref)["publish"], "false")

    def test_reject_unpinned_base(self):
        with self.assertRaises(ValueError):
            self.result(source="ARG BASE_IMAGE=ghcr.io/example/image:latest")

    def test_version_comes_from_base(self):
        result = self.result(source="ARG BASE_IMAGE=ghcr.io/example/image:dsh-v9.8.7-rc.1@sha256:" + "b" * 64)
        self.assertEqual(result["image_tag"], "dsh-v9.8.7-rc.1-aaaaaaa")


if __name__ == "__main__":
    unittest.main()
