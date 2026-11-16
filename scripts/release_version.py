"""Compute the next release version and iOS build number from the repository's tags.

release.yml pipes `git ls-remote --tags <repo>` into this script and appends its
`key=value` output to $GITHUB_OUTPUT. Keep it stdlib-only: it runs with the
runner's system python3, before uv is set up.
"""

import argparse
import re
import sys

PURE_TAG = re.compile(
    r"^refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\^\{\})?$"
)
# CFBundleVersion must grow with every release: major * 1_000_000 + minor * 1_000 + patch.
COMPONENT_LIMIT = 1000


def pure_tags(ls_remote):
    """Yield (commit-or-tag-object sha, (major, minor, patch)) for each pure vX.Y.Z ref."""
    for line in ls_remote.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        match = PURE_TAG.match(parts[1])
        if match:
            yield parts[0], tuple(int(group) for group in match.groups()[:3])


def bump_version(base, bump):
    major, minor, patch = base
    if bump == "major":
        return major + 1, 0, 0
    if bump == "minor":
        return major, minor + 1, 0
    return major, minor, patch + 1


def build_number(version):
    major, minor, patch = version
    if minor >= COMPONENT_LIMIT or patch >= COMPONENT_LIMIT:
        raise ValueError(
            f"minor 与 patch 须小于 {COMPONENT_LIMIT}，build 号公式才单调递增"
        )
    return major * 1_000_000 + minor * 1_000 + patch


def plan(ls_remote, bump, head):
    """Return (version string, build number, released tags already on head)."""
    tags = list(pure_tags(ls_remote))
    base = max((version for _, version in tags), default=(0, 0, 0))
    version = bump_version(base, bump)
    on_head = sorted(
        {"v{}.{}.{}".format(*tagged) for sha, tagged in tags if sha == head}
    )
    return "{}.{}.{}".format(*version), build_number(version), on_head


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bump", choices=("patch", "minor", "major"), required=True)
    parser.add_argument("--head", required=True, help="commit to be released")
    parser.add_argument(
        "--require-unreleased",
        action="store_true",
        help="fail when --head already carries a pure vX.Y.Z tag",
    )
    args = parser.parse_args()
    try:
        version, build, on_head = plan(sys.stdin.read(), args.bump, args.head)
    except ValueError as error:
        sys.exit(f"error: {error}")
    if on_head and args.require_unreleased:
        sys.exit(
            f"error: 这个提交已发过版（{', '.join(on_head)}）；"
            "有新提交后再发下一个版本。"
        )
    print(f"version={version}")
    print(f"build={build}")
    print(f"tag=v{version}")


if __name__ == "__main__":
    main()
