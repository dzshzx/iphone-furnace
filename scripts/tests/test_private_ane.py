from pathlib import Path
import struct
import subprocess

import numpy as np
import pytest
from coremltools.libmilstoragepython import _BlobStorageReader

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def native_probe(tmp_path_factory):
    executable = tmp_path_factory.mktemp("native-ane") / "probe"
    subprocess.run(
        [
            "c++",
            "-std=c++20",
            "-O2",
            "-I",
            str(ROOT / "Sources/Native"),
            str(Path(__file__).with_name("ane_model_data_probe.cpp")),
            "-o",
            str(executable),
        ],
        check=True,
    )
    return executable


def test_real_framework_identifier_is_accepted_without_allowing_paths(native_probe):
    # Shape observed from macOS 27 _ANEInMemoryModel.hexStringIdentifier.
    composite = "A" * 64 + "_" + "B" * 64 + "_" + "C" * 64
    for identifier in ["0123456789abcdefABCDEF", composite]:
        assert subprocess.run([native_probe, "identifier", identifier]).returncode == 0
    for identifier in [
        "",
        ".",
        "..",
        "../AB",
        "AB/CD",
        "/AB",
        "AB\\CD",
        "AB\nCD",
        "AB CD",
        "AB%2fCD",
        "_AB",
        "AB_",
        "AB__CD",
        "AB_GH",
        "A" * 256,
    ]:
        assert subprocess.run([native_probe, "identifier", identifier]).returncode == 2
    assert subprocess.run([native_probe, "embedded-null"]).returncode == 2


@pytest.mark.parametrize("channels", [256, 384, 512])
def test_private_weights_are_readable_by_coremltools(native_probe, tmp_path, channels):
    path = tmp_path / "weight.bin"
    subprocess.run([native_probe, "weights", str(channels), path], check=True)
    reader = _BlobStorageReader(str(path))
    accumulated = np.ones(channels, dtype=np.float32)
    for layer in range(16):
        offset = 64 + layer * (64 + channels * channels * 2)
        values = reader.read_fp16_data(offset).view(np.float16)
        assert values.size == channels * channels
        assert np.isfinite(values).all() and (values > 0).all()
        weights = values.astype(np.float32).reshape(channels, channels)
        accumulated = weights @ accumulated
    np.testing.assert_allclose(accumulated, 1.0, atol=0.003)
    assert struct.unpack_from("<II", path.read_bytes()) == (16, 2)
