"""Reject simulator builds, incomplete model bundles and accidentally signed IPAs."""

import argparse
import plistlib
import struct
import tempfile
import zipfile

from macholib.MachO import MachO
from macholib.mach_o import CPU_TYPE_NAMES, LC_BUILD_VERSION, MH_MAGIC_64


def build_platforms(binary):
    """Return LC_BUILD_VERSION platforms of a thin arm64 Mach-O executable."""
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(binary)
        handle.flush()
        try:
            headers = MachO(handle.name).headers
        except (ValueError, OSError, struct.error) as error:
            raise AssertionError(f"malformed Mach-O: {error}") from error
    assert len(headers) == 1, "expected thin arm64 Mach-O"
    header = headers[0]
    assert (
        header.header.magic == MH_MAGIC_64
        and CPU_TYPE_NAMES.get(header.header.cputype) == "ARM64"
    ), "expected arm64 Mach-O"
    return [
        command.platform
        for load, command, _ in header.commands
        if load.cmd == LC_BUILD_VERSION
    ]


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        prefix = "Payload/Furnace.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], (
            "not an iPhone device build"
        )
        assert info["MinimumOSVersion"] == "27.0", "wrong deployment target"
        binary = archive.read(prefix + info["CFBundleExecutable"])
        platforms = build_platforms(binary)
        assert platforms == [2], f"expected iOS platform, found {platforms}"
        for channels in (256, 384, 512):
            assert any(
                n.startswith(prefix + f"Stress{channels}.mlmodelc/") for n in names
            ), "missing model"
        assert prefix + "default.metallib" in names, "missing Metal library"
        assert not any(
            "/_CodeSignature/" in n or n.endswith("embedded.mobileprovision")
            for n in names
        ), "expected unsigned IPA"
        print(
            f"Verified unsigned arm64 iOS {info['MinimumOSVersion']} IPA with all three models and Metal kernels"
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    verify(parser.parse_args().ipa)
