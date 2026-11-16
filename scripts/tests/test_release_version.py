import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_version import build_number, plan

SCRIPT = Path(__file__).resolve().parents[1] / "release_version.py"
HEAD = "c" * 40
LS_REMOTE = "\n".join(
    [
        f"{'a' * 40}\trefs/tags/v0.1.0",
        f"{HEAD}\trefs/tags/v0.1.0^{{}}",
        f"{'b' * 40}\trefs/tags/v0.9.0",
        f"{'d' * 40}\trefs/tags/v0.10.0-rc1",
        f"{'e' * 40}\trefs/tags/v1.0",
        f"{'f' * 40}\trefs/tags/release-2.0.0",
        f"{'1' * 40}\trefs/tags/v0.10.0x",
        f"{'2' * 40}\trefs/heads/v9.9.9",
    ]
)


@pytest.mark.parametrize(
    ("bump", "version"),
    [("patch", "0.9.1"), ("minor", "0.10.0"), ("major", "1.0.0")],
)
def test_bumps_the_highest_pure_semver_tag(bump, version):
    assert plan(LS_REMOTE, bump, "0" * 40)[0] == version


def test_compares_numerically_not_as_text():
    tags = f"{'a' * 40}\trefs/tags/v0.9.0\n{'b' * 40}\trefs/tags/v0.10.0\n"
    assert plan(tags, "patch", HEAD)[0] == "0.10.1"


def test_first_release_starts_from_zero():
    assert plan("", "patch", HEAD)[:2] == ("0.0.1", 1)


def test_reports_pure_tags_on_head_through_peeled_annotated_refs():
    assert plan(LS_REMOTE, "patch", HEAD)[2] == ["v0.1.0"]
    assert plan(LS_REMOTE, "patch", "0" * 40)[2] == []


def test_build_number_grows_with_every_version_order():
    ordered = [(0, 1, 0), (0, 1, 1), (0, 1, 999), (0, 2, 0), (0, 999, 999), (1, 0, 0)]
    numbers = [build_number(version) for version in ordered]
    assert numbers == sorted(numbers) and len(set(numbers)) == len(numbers)
    assert build_number((0, 1, 1)) == 1001
    with pytest.raises(ValueError):
        build_number((0, 1000, 0))


def run(*args, stdin=LS_REMOTE):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )


def test_cli_prints_github_outputs():
    result = run("--bump", "patch", "--head", "0" * 40, "--require-unreleased")
    assert result.returncode == 0
    assert result.stdout == "version=0.9.1\nbuild=9001\ntag=v0.9.1\n"


def test_cli_refuses_a_head_that_is_already_released_unless_dry_run():
    refused = run("--bump", "patch", "--head", HEAD, "--require-unreleased")
    assert refused.returncode != 0
    assert "已发过版" in refused.stderr and refused.stdout == ""
    assert run("--bump", "patch", "--head", HEAD).returncode == 0
