# Verified CoreML byte-asset fixture

This tiny `y = x * 2` ML Program is project-authored test material. It is not a
transcription model and contains no provider or model-repository data. The model
has one ten-element `float32` input, one ten-element `float32` output, and a
ten-element external `float32` scale constant containing only `2.0`.

## One-time hash-pinned generation recipe

The fixture was generated once in an isolated environment using exactly:

- Python **3.12.7**
- `coremltools==9.0`
- NumPy **2.5.1**

`coremltools` is a BSD-3-Clause licensed build tool and is not a MacTalk
runtime or project dependency. The generation environment is intentionally not
checked in and tests never invoke it. The committed `model.mlmodel` and
`weights/weight.bin` are the two files under `Data/com.apple.CoreML` from the
resulting package.

The recipe below documents the model semantics, but it is **not byte-
reproducible**. `coremltools` embeds `conversion_date` and other non-semantic
metadata, so regenerating on another date or with a different toolchain can
produce different bytes. The canonical trust source is the committed
`fixture-manifest.json` hash/size record, exercised by the byte-loader tests;
those tests also verify the declared interface and exact prediction values.

```python
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types
import numpy as np

@mb.program(input_specs=[mb.TensorSpec(shape=(10,), dtype=types.fp32)],
            opset_version=ct.target.macOS26)
def prog(x):
    scale = mb.const(val=np.full((10,), 2.0, dtype=np.float32), name="scale")
    return mb.mul(x=x, y=scale, name="double")

model = ct.convert(prog, convert_to="mlprogram",
                   minimum_deployment_target=ct.target.macOS26)
model.save("VerifiedCoreMLFixture.mlpackage")
```

The fixture is distributed as project-authored test material. Only generated
bytes and the strict manifest are committed; no virtualenv, pip metadata,
provider artifact, or model download is included.
