"""派生镜像的固定版本、变更判断和发布权限；不读取仓库变量覆盖基础镜像。"""
import os
from pathlib import Path
import re
import subprocess


def metadata(containerfile, event, ref, sha, repository, changed=None):
    match = re.search(r"^ARG BASE_IMAGE=(ghcr\.io/[^\s]+:(dsh-v[0-9][\w.-]*)@sha256:[a-f0-9]{64})$", containerfile, re.M)
    if not match:
        raise ValueError("BASE_IMAGE must pin a dsh-v tag and sha256 digest")
    if not re.fullmatch(r"[a-f0-9]{40}", sha):
        raise ValueError("Expected a full commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid repository")
    publish = event == "push" and ref == "refs/heads/main"
    # 只有 PR 可走文档快车道；空 diff、不可读取的 diff 均执行构建。
    docs_only = event == "pull_request" and bool(changed) and all(
        path.endswith(".md") or path == "LICENSE" for path in changed)
    return dict(build=str(not docs_only).lower(), publish=str(publish).lower(),
                base_image=match[1], image_tag=f"{match[2]}-{sha[:7]}",
                image="ghcr.io/" + repository.lower())


def main():
    event = os.environ["EVENT"]
    changed = None
    if event == "pull_request" and os.environ.get("PR_BASE"):
        try:
            changed = subprocess.check_output(
                ["git", "diff", "--name-only", os.environ["PR_BASE"], os.environ["SHA"]],
                text=True).splitlines()
        except subprocess.CalledProcessError:
            pass
    result = metadata(Path("Containerfile").read_text(), event, os.environ["REF"],
                      os.environ["SHA"], os.environ["REPOSITORY"], changed)
    for key, value in result.items():
        print(f"{key}={value}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write("### Image decision\n\n" + "\n".join(
                f"- {key}: `{value}`" for key, value in result.items()) + "\n")


if __name__ == "__main__":
    main()
