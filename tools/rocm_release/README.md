# ROCm 7.11 release helpers

This directory is the source of truth for the custom ROCm 7.11 packaging flow around this fork.

Scope:
- build the custom `torch` wheel from this repo
- build matching companion wheels for `torchcodec` and `torchaudio`
- promote all three wheels to `/opt/rocm/wheels/pytorch_rocm711/`
- install the promoted wheel family into project venvs with the required ROCm runtime environment

TheRock validation should consume the promoted wheel family from `/opt/rocm` and validate runtime behavior.
It should not own the packaging scripts.

## Layout

- `build_torchcodec_rocm_wheel.sh`
- `build_torchaudio_rocm_wheel.sh`
- `install_pytorch_rocm_wheel_to_opt.sh`
- `install_torchcodec_rocm_wheel_to_opt.sh`
- `install_torchaudio_rocm_wheel_to_opt.sh`
- `install_pytorch_rocm_wheel_to_venv.sh`

Default local workspace:
- `./.rocm_release/git/`
- `./.rocm_release/wheels/pytorch_rocm711/`
- `./.rocm_release/venvs/`
- `./.rocm_release/install-backups/`

## Typical flow

Build `torch` with the existing repo-native flow so that a wheel lands in `./dist/`.
Then:

```bash
./tools/rocm_release/install_pytorch_rocm_wheel_to_opt.sh ./dist/torch-*.whl
./tools/rocm_release/build_torchcodec_rocm_wheel.sh --rocm-prefix /opt/rocm
./tools/rocm_release/install_torchcodec_rocm_wheel_to_opt.sh
./tools/rocm_release/build_torchaudio_rocm_wheel.sh --rocm-prefix /opt/rocm
./tools/rocm_release/install_torchaudio_rocm_wheel_to_opt.sh
```

`install_pytorch_rocm_wheel_to_opt.sh` rewrites embedded RPATH/RUNPATH entries
inside the `torch` wheel before promotion so the installed wheel no longer
points back to an in-tree ROCm build directory such as
`build-stage2/dist/rocm/lib`.

That keeps the flow aligned with the other custom wheel families:
- build and verify against the repo-local output first
- promote a system-safe wheel into `/opt/rocm`
- validate the promoted install separately against `/opt/rocm`

Consumer projects can then install the promoted family with:

```bash
./tools/rocm_release/install_pytorch_rocm_wheel_to_venv.sh --venv .venv --rocm-prefix /opt/rocm
```

Stable system aliases:
- `/opt/rocm/wheels/pytorch_rocm711/torch-current.whl`
- `/opt/rocm/wheels/pytorch_rocm711/torchcodec-current.whl`
- `/opt/rocm/wheels/pytorch_rocm711/torchaudio-current.whl`

## Notes

- These helpers assume a system ROCm install under `/opt/rocm` for the promoted/consumer path.
- If `/opt/rocm` is not available yet, they can fall back to `<repo>/<build-dir>/dist/rocm` for local build verification.
- The consuming venv should currently pin `numpy<2` until the custom wheel family is rebuilt for NumPy 2.x ABI compatibility.
