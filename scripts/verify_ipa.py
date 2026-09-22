"""Reject simulator builds, incomplete model bundles and accidentally signed IPAs."""
import argparse
import plistlib
import struct
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        prefix = "Payload/Furnace.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "not an iPhone device build"
        assert info["MinimumOSVersion"] == "27.0", "wrong deployment target"
        binary = archive.read(prefix + info["CFBundleExecutable"])
        magic, cpu, _, _, count, _, _, _ = struct.unpack_from("<8I", binary)
        assert magic == 0xFEEDFACF and cpu == 0x0100000C, "expected arm64 Mach-O"
        offset = 32
        platforms = []
        for _ in range(count):
            command, size = struct.unpack_from("<II", binary, offset)
            assert size >= 8 and offset + size <= len(binary), "malformed load command"
            if command == 0x32:
                platforms.append(struct.unpack_from("<I", binary, offset + 8)[0])
            offset += size
        assert platforms == [2], f"expected iOS platform, found {platforms}"
        for channels in (256, 384, 512):
            assert any(n.startswith(prefix + f"Stress{channels}.mlmodelc/") for n in names), "missing model"
        assert prefix + "default.metallib" in names, "missing Metal library"
        assert not any("/_CodeSignature/" in n or n.endswith("embedded.mobileprovision") for n in names), "expected unsigned IPA"
        print(f"Verified unsigned arm64 iOS {info['MinimumOSVersion']} IPA with all three models and Metal kernels")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa")
    verify(parser.parse_args().ipa)

