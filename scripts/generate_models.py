"""Generate deterministic, input-dependent FP16 ANE candidates; no downloaded weights."""

from pathlib import Path
import argparse
import json
import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types


def make_model(channels: int, depth: int = 16):
    rng = np.random.default_rng(20260922 + channels)
    # Positive small coefficients keep outputs finite/nonzero through every
    # layer. Each channel has different weights; ReLU prevents conv fusion.
    weights = [
        rng.uniform(0.25, 1.75, (channels, channels, 1, 1)).astype(np.float16)
        / channels
        for _ in range(depth)
    ]

    @mb.program(
        input_specs=[mb.TensorSpec(shape=(1, channels, 64, 64), dtype=types.fp16)],
        opset_version=ct.target.iOS18,
    )
    def program(x):
        for i, weight in enumerate(weights):
            x = mb.conv(x=x, weight=weight.astype(np.float16), name=f"conv_{i}")
            x = mb.relu(x=x, name=f"relu_{i}")
        return mb.identity(x=x, name="result")

    model = ct.convert(
        program,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )
    model.author = "Furnace"
    model.short_description = (
        f"Synthetic FP16 stress graph: 16 conv/relu layers, {channels} channels."
    )
    model.input_description["x"] = "Runtime FP16 input, NCHW 1xCx64x64"
    return model


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("Models"))
    parser.add_argument("--channels", nargs="+", type=int, default=[256, 384, 512])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = []
    for channels in args.channels:
        if channels not in (256, 384, 512):
            raise ValueError("unsupported channel count")
        model = make_model(channels)
        name = f"Stress{channels}.mlpackage"
        model.save(str(args.output / name))
        manifest.append(
            {
                "name": name,
                "channels": channels,
                "depth": 16,
                "shape": [1, channels, 64, 64],
            }
        )
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
