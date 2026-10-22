# Publication

Every push to main builds and tests linux/amd64 and linux/arm64 on native runners, even for
documentation-only changes. Both must pass before the combined manifest and latest tag are
published to ghcr.io/huyyi/dsh-container.

The version tag is the upstream dsh tag from Containerfile plus the first seven characters of
the repository commit SHA: for example, dsh-v0.2.1-rc.2-cf05a2f. Architecture staging tags add
-amd64 or -arm64; final version/latest tags reference both platforms. A failed build can leave
a staging tag, but does not update the combined tags.

PRs only validate. Markdown/LICENSE-only PRs skip image builds, and unknown diffs build.
Manual dispatch also only validates. Git tag pushes do not trigger the Image workflow.
There is no GitHub Release, upstream watcher, release-prep agent or PAT probe workflow.

The workflow derives the base, image label and permissions in scripts/image_metadata.py;
repository variables cannot override the pinned base. Update the pin in a reviewed commit.
Publishing main is automatic once this workflow is merged; do not merge PRs without authorization.

Runtime homes survive image replacement. Back up homes before upgrades and verify plugin
compatibility. Existing user-installed plugins are preserved by the seeder.
