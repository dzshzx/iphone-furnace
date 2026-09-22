import importlib.util
from pathlib import Path
import plistlib
import struct
import zipfile
import pytest
from coremltools.models.utils import load_spec

MODULE_PATH = Path(__file__).parents[1] / "verify_ipa.py"
SPEC = importlib.util.spec_from_file_location("verify_ipa", MODULE_PATH)
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


def package(path, platform=2, missing_model=False, signed=False):
    prefix = "Payload/Furnace.app/"
    binary = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
    binary += struct.pack("<6I", 0x32, 24, platform, 0, 0, 0)
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(prefix + "Info.plist", plistlib.dumps({
            "CFBundleExecutable": "Furnace", "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "27.0"}))
        archive.writestr(prefix + "Furnace", binary)
        archive.writestr(prefix + "default.metallib", b"test fixture")
        for channels in (256, 384, 512):
            if channels == 512 and missing_model:
                continue
            archive.writestr(prefix + f"Stress{channels}.mlmodelc/model.mil", b"fixture")
        if signed:
            archive.writestr(prefix + "_CodeSignature/CodeResources", b"fixture")


def test_device_package_and_rejection_of_simulator_missing_models_and_signatures(tmp_path):
    path = tmp_path / "test.ipa"
    package(path)
    verifier.verify(path)
    for options in ({"platform": 7}, {"missing_model": True}, {"signed": True}):
        package(path, **options)
        with pytest.raises(AssertionError):
            verifier.verify(path)


@pytest.mark.parametrize("channels", [256, 384, 512])
def test_generated_graph_retains_runtime_input_and_compute_layers(channels):
    spec = load_spec(f"Models/Stress{channels}.mlpackage")
    assert list(spec.description.input[0].type.multiArrayType.shape) == [1, channels, 64, 64]
    assert spec.description.input[0].name == "x"
    assert spec.description.output[0].name == "result"
    blocks = list(spec.mlProgram.functions["main"].block_specializations.values())
    operations = [op.type for block in blocks for op in block.operations]
    assert operations.count("conv") == 16
    assert operations.count("relu") == 16
