# ROCm 7.11 PyTorch release helpers

This directory is the source of truth for the custom ROCm 7.11 packaging flow
around this fork.

Scope:
- build/promote the custom `torch` wheel from this repo
- build matching companion wheels for `torchcodec` and `torchaudio`
- probe NumPy C-ABI compatibility before promotion
- create deterministic ROCm/PyTorch venvs without install-order traps
- promote all three wheels to `/opt/rocm/wheels/pytorch_rocm711/`

TheRock validation should consume the promoted wheel family from `/opt/rocm` and
validate runtime behavior. It should not own the packaging scripts.

## Layout

- `create_rocm_venv.sh`
- `probe_numpy_abi.sh`
- `build_torchcodec_rocm_wheel.sh`
- `build_torchaudio_rocm_wheel.sh`
- `install_pytorch_rocm_wheel_to_opt.sh`
- `install_torchcodec_rocm_wheel_to_opt.sh`
- `install_torchaudio_rocm_wheel_to_opt.sh`
- `install_pytorch_rocm_wheel_to_venv.sh` compatibility wrapper for `create_rocm_venv.sh`

Default local release root:
- `./.rocm_release/git/`
- `./.rocm_release/wheels/pytorch_rocm711/`
- `./.rocm_release/venvs/`
- `./.rocm_release/install-backups/`

Canonical override:
- `RELEASE_ROOT=/path/to/release-state`

Compatibility note:
- `WORKSPACE_DIR` is still accepted as a legacy alias for `RELEASE_ROOT`.

## Runtime policy

Use the generated venv as the supported runtime boundary. The helper writes:

- `<venv>/bin/rocm_pytorch_env.sh`
- `<venv>/bin/python-rocm`
- `<venv>/bin/pip-rocm`
- `<venv>/rocm711-constraints.txt`

By default it also patches `<venv>/bin/activate`, so normal activation sources
the ROCm runtime environment before Python starts:

```bash
source .venv/bin/activate
python -c 'import torch; print(torch.cuda.is_available())'
```

The wrapper remains available for scripts and systemd-style launchers:

```bash
.venv/bin/python-rocm -c 'import torch; print(torch.cuda.is_available())'
```

Install additional application packages through `pip-rocm`, not raw `pip`, so
pip cannot replace the custom wheel family with incompatible public wheels:

```bash
.venv/bin/pip-rocm install openai-whisper
```

This fixes the old manual-order workaround. The deterministic order is now owned
by `create_rocm_venv.sh`:

1. install the selected NumPy ABI policy
2. install custom `torch` with `--no-deps`
3. install custom `torchcodec` with `--no-deps`
4. install custom `torchaudio` with `--no-deps`
5. install app packages through generated constraints
6. run the ROCm GPU smoke test

## Create a consumer venv

After promotion:

```bash
bash tools/rocm_release/create_rocm_venv.sh \
  --venv .venv \
  --rocm-prefix /opt/rocm \
  -y
```

With Whisper installed in the same deterministic transaction:

```bash
bash tools/rocm_release/create_rocm_venv.sh \
  --venv .venv \
  --rocm-prefix /opt/rocm \
  --install openai-whisper \
  -y
```

Legacy entrypoint, kept for older notes/scripts:

```bash
bash tools/rocm_release/install_pytorch_rocm_wheel_to_venv.sh \
  --venv .venv \
  --rocm-prefix /opt/rocm \
  -y
```

It delegates to `create_rocm_venv.sh`.

## NumPy ABI policy

The old promoted PyTorch wheel family used `numpy<2` as a runtime guard because
native Python extensions built against the NumPy 1.x C-ABI can fail when
imported with NumPy 2.x.

The intended forward path is now:

```text
new wheels: build/probe with NUMPY_SPEC='numpy>=2,<3'
legacy repro: set NUMPY_SPEC='numpy<2'
```

Do not remove all `numpy<2` pins blindly. First rebuild the complete PyTorch
wheel family, then probe it with NumPy 2, then promote it.

## Probe the current promoted wheels

```bash
bash tools/rocm_release/probe_numpy_abi.sh \
  --numpy-spec 'numpy>=2,<3' \
  --rocm-prefix /opt/rocm \
  --require-gpu
```

Legacy comparison:

```bash
bash tools/rocm_release/probe_numpy_abi.sh \
  --numpy-spec 'numpy<2' \
  --rocm-prefix /opt/rocm
```

## NumPy 2 rebuild flow

Build `torch` first with the repo-native PyTorch build flow so that a wheel lands
in `./dist/`. The build environment should already contain NumPy 2 before
`setup.py bdist_wheel` runs.

Recommended build-env preflight:

```bash
python -m pip install -U pip setuptools wheel
python -m pip install --force-reinstall 'numpy>=2,<3'
python - <<'PY'
import numpy as np
print('build numpy:', np.__version__)
PY
```

After the new `torch-*.whl` exists:

```bash
export NUMPY_SPEC='numpy>=2,<3'
export ROCM_PREFIX=/opt/rocm

bash tools/rocm_release/build_torchcodec_rocm_wheel.sh \
  --torch-wheel ./dist/torch-*.whl \
  --rocm-prefix "$ROCM_PREFIX" \
  --numpy-spec "$NUMPY_SPEC"

bash tools/rocm_release/build_torchaudio_rocm_wheel.sh \
  --torch-wheel ./dist/torch-*.whl \
  --rocm-prefix "$ROCM_PREFIX" \
  --numpy-spec "$NUMPY_SPEC"
```

Probe the newly built local wheel family before promotion:

```bash
bash tools/rocm_release/probe_numpy_abi.sh \
  --numpy-spec 'numpy>=2,<3' \
  --wheel-dir .rocm_release/wheels/pytorch_rocm711 \
  --torch-wheel ./dist/torch-*.whl \
  --rocm-prefix /opt/rocm \
  --require-gpu
```

## Promote after successful NumPy 2 probe

```bash
sudo bash tools/rocm_release/install_pytorch_rocm_wheel_to_opt.sh ./dist/torch-*.whl
sudo bash tools/rocm_release/install_torchcodec_rocm_wheel_to_opt.sh
sudo bash tools/rocm_release/install_torchaudio_rocm_wheel_to_opt.sh
```

Stable system aliases after promotion:
- `/opt/rocm/wheels/pytorch_rocm711/torch-current.whl`
- `/opt/rocm/wheels/pytorch_rocm711/torchcodec-current.whl`
- `/opt/rocm/wheels/pytorch_rocm711/torchaudio-current.whl`

Then probe the promoted state again:

```bash
bash tools/rocm_release/probe_numpy_abi.sh \
  --numpy-spec 'numpy>=2,<3' \
  --rocm-prefix /opt/rocm \
  --require-gpu
```

## Notes

- These helpers assume a system ROCm install under `/opt/rocm` for the
  promoted/consumer path.
- If `/opt/rocm` is not available yet, they can fall back to
  `<repo>/<build-dir>/dist/rocm` for local build verification.
- Keep `NUMPY_SPEC='numpy<2'` only for old-wheel reproduction or bisecting.
- Promote `torch`, `torchcodec`, and `torchaudio` as a matching family. Mixing
  a new NumPy-2 `torch` wheel with old companion wheels can reintroduce ABI or
  binary compatibility problems.
- The deeper remaining technical debt is `libomp`: the venv wrapper still
  preloads `/opt/rocm/lib/llvm/lib/libomp.so` because current wheels can expose
  unresolved `__kmpc_*` symbols. The wrapper makes this deterministic and
  order-independent for users.
