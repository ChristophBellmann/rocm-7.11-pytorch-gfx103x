#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

cat <<'NOTE'
NOTE: install_pytorch_rocm_wheel_to_venv.sh is kept as a compatibility entrypoint.
      It now delegates to create_rocm_venv.sh, which installs the custom ROCm
      PyTorch wheel family in a deterministic order, writes python-rocm/pip-rocm
      wrappers, generates constraints, and patches venv activation.
NOTE

exec "${ROOT}/tools/rocm_release/create_rocm_venv.sh" "$@"
