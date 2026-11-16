import pytest
from coremltools.models.utils import load_spec


@pytest.mark.parametrize("channels", [256, 384, 512])
def test_generated_graph_retains_runtime_input_and_compute_layers(channels):
    spec = load_spec(f"Models/Stress{channels}.mlpackage")
    assert list(spec.description.input[0].type.multiArrayType.shape) == [
        1,
        channels,
        64,
        64,
    ]
    assert spec.description.input[0].name == "x"
    assert spec.description.output[0].name == "result"
    blocks = list(spec.mlProgram.functions["main"].block_specializations.values())
    operations = [op.type for block in blocks for op in block.operations]
    assert operations.count("conv") == 16
    assert operations.count("relu") == 16
