#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-build}"
LEGACY_WORKSPACE_DIR="${WORKSPACE_DIR:-}"
RELEASE_ROOT="${RELEASE_ROOT:-${LEGACY_WORKSPACE_DIR:-${ROOT}/.rocm_release}}"
WORKSPACE_DIR="${RELEASE_ROOT}"
ROCM_PREFIX="${ROCM_PREFIX:-/opt/rocm}"
WHEEL_DIR="${WHEEL_DIR:-}"
TORCH_WHEEL_PATH="${TORCH_WHEEL_PATH:-}"
TORCHCODEC_WHEEL_PATH="${TORCHCODEC_WHEEL_PATH:-}"
TORCHAUDIO_WHEEL_PATH="${TORCHAUDIO_WHEEL_PATH:-}"
NUMPY_SPEC="${NUMPY_SPEC:-numpy>=2,<3}"
VENV_DIR="${VENV_DIR:-}"
INSTALL_COMPANIONS=1
REQUIRE_GPU=0
KEEP_VENV=0

usage() {
  cat <<'USAGE'
Usage: probe_numpy_abi.sh [options]

Creates a clean probe venv, installs the selected NumPy version and the custom
ROCm PyTorch wheel family, then imports the native modules. The import probe is
run from /tmp so a source checkout cannot shadow the installed torch wheel.

Options:
  --numpy-spec <spec>        NumPy requirement to probe (default: numpy>=2,<3)
  --torch-wheel <path>       Explicit torch wheel
  --torchcodec-wheel <path>  Explicit torchcodec wheel
  --torchaudio-wheel <path>  Explicit torchaudio wheel
  --wheel-dir <dir>          Wheel directory
  --rocm-prefix <dir>        ROCm prefix for runtime env
  --build-dir <dir>          Fallback in-tree build dir (default: build)
  --venv <dir>               Reuse/create a specific probe venv
  --no-companions            Probe only torch
  --require-gpu              Also require torch.cuda.is_available()
  --keep-venv                Keep temporary venv after the probe
  -h, --help                 Show help
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found"; }

choose_rocm_prefix() {
  if [[ -d "${ROCM_PREFIX}" ]]; then echo "${ROCM_PREFIX}"; return 0; fi
  local fallback="${ROOT}/${BUILD_DIR}/dist/rocm"
  if [[ -d "${fallback}" ]]; then echo "${fallback}"; return 0; fi
  die "ROCm prefix not found: '${ROCM_PREFIX}' and fallback missing: '${fallback}'"
}

choose_wheel_dir() {
  if [[ -n "${WHEEL_DIR}" ]]; then echo "${WHEEL_DIR}"; return 0; fi
  if [[ -d "${ROCM_PREFIX}/wheels/pytorch_rocm711" ]]; then echo "${ROCM_PREFIX}/wheels/pytorch_rocm711"; return 0; fi
  echo "${WORKSPACE_DIR}/wheels/pytorch_rocm711"
}

latest_or_empty() { local pattern="$1"; ls -1t ${pattern} 2>/dev/null | head -n 1 || true; }

resolve_wheel() {
  local explicit="$1" dir="$2" current_name="$3" glob_name="$4"
  if [[ -n "${explicit}" ]]; then
    [[ -f "${explicit}" ]] || die "Wheel not found: ${explicit}"
    readlink -f "${explicit}"
    return 0
  fi
  if [[ -f "${dir}/${current_name}" ]]; then readlink -f "${dir}/${current_name}"; return 0; fi
  local found
  found="$(latest_or_empty "${dir}/${glob_name}")"
  if [[ -n "${found}" ]]; then readlink -f "${found}"; return 0; fi
  found="$(latest_or_empty "${ROOT}/dist/${glob_name}")"
  if [[ -n "${found}" ]]; then readlink -f "${found}"; return 0; fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --numpy-spec) NUMPY_SPEC="${2:-}"; shift 2 ;;
    --torch-wheel) TORCH_WHEEL_PATH="${2:-}"; shift 2 ;;
    --torchcodec-wheel) TORCHCODEC_WHEEL_PATH="${2:-}"; shift 2 ;;
    --torchaudio-wheel) TORCHAUDIO_WHEEL_PATH="${2:-}"; shift 2 ;;
    --wheel-dir) WHEEL_DIR="${2:-}"; shift 2 ;;
    --rocm-prefix) ROCM_PREFIX="${2:-}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:-}"; shift 2 ;;
    --venv) VENV_DIR="${2:-}"; shift 2 ;;
    --no-companions) INSTALL_COMPANIONS=0; shift ;;
    --require-gpu) REQUIRE_GPU=1; shift ;;
    --keep-venv) KEEP_VENV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

need_cmd python3

rocm_use="$(choose_rocm_prefix)"
wheel_dir="$(choose_wheel_dir)"
[[ -d "${wheel_dir}" ]] || die "Wheel dir not found: ${wheel_dir}"

torch_wheel="$(resolve_wheel "${TORCH_WHEEL_PATH}" "${wheel_dir}" "torch-current.whl" "torch-*.whl")" || die "No torch wheel found"

torchcodec_wheel=""
torchaudio_wheel=""
if (( INSTALL_COMPANIONS )); then
  torchcodec_wheel="$(resolve_wheel "${TORCHCODEC_WHEEL_PATH}" "${wheel_dir}" "torchcodec-current.whl" "torchcodec-*.whl" || true)"
  torchaudio_wheel="$(resolve_wheel "${TORCHAUDIO_WHEEL_PATH}" "${wheel_dir}" "torchaudio-current.whl" "torchaudio-*.whl" || true)"
fi

created_tmp=0
if [[ -z "${VENV_DIR}" ]]; then
  VENV_DIR="$(mktemp -d -t rocm-numpy-abi-probe-XXXXXX)"
  created_tmp=1
fi
cleanup() {
  if (( created_tmp )) && (( ! KEEP_VENV )); then rm -rf "${VENV_DIR}"; fi
}
trap cleanup EXIT

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  mkdir -p "$(dirname "${VENV_DIR}")"
  python3 -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

export ROCM_PATH="${rocm_use}"
export HIP_PATH="${HIP_PATH:-$ROCM_PATH}"
export HSA_PATH="${HSA_PATH:-$ROCM_PATH}"
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:${VENV_DIR}/bin:${PATH:-}"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib64:$ROCM_PATH/lib/llvm/lib:$ROCM_PATH/lib/host-math/lib:$ROCM_PATH/lib/rocm_sysdeps/lib:$ROCM_PATH/llvm/lib:${LD_LIBRARY_PATH:-}"
if [[ -f "$ROCM_PATH/lib/llvm/lib/libomp.so" ]]; then
  export LD_PRELOAD="$ROCM_PATH/lib/llvm/lib/libomp.so${LD_PRELOAD:+:${LD_PRELOAD}}"
fi

cat <<EOF
== NumPy ABI probe ==
venv       : ${VENV_DIR}
NumPy spec : ${NUMPY_SPEC}
ROCm       : ${rocm_use}
wheel dir  : ${wheel_dir}
torch      : ${torch_wheel}
torchcodec : ${torchcodec_wheel:-<not probed>}
torchaudio : ${torchaudio_wheel:-<not probed>}
require GPU: ${REQUIRE_GPU}
EOF

python -m pip install -U pip setuptools wheel >/dev/null
python -m pip install --force-reinstall "${NUMPY_SPEC}"
python -m pip install -U typing-extensions filelock fsspec jinja2 networkx sympy >/dev/null
python -m pip install --no-deps --force-reinstall "${torch_wheel}"
if [[ -n "${torchcodec_wheel}" ]]; then python -m pip install --no-deps --force-reinstall "${torchcodec_wheel}"; fi
if [[ -n "${torchaudio_wheel}" ]]; then python -m pip install --no-deps --force-reinstall "${torchaudio_wheel}"; fi

export ROCM_NUMPY_ABI_REQUIRE_GPU="${REQUIRE_GPU}"
export ROCM_NUMPY_ABI_EXPECT_TORCHCODEC="$([[ -n "${torchcodec_wheel}" ]] && echo 1 || echo 0)"
export ROCM_NUMPY_ABI_EXPECT_TORCHAUDIO="$([[ -n "${torchaudio_wheel}" ]] && echo 1 || echo 0)"

(
  cd /tmp
  python - <<'PY'
import os
import numpy as np
print("numpy      :", np.__version__)

import torch
print("torch      :", getattr(torch, "__version__", ""))
print("torch file :", getattr(torch, "__file__", ""))
print("hip        :", getattr(torch.version, "hip", None))
print("rocm       :", getattr(torch.version, "rocm", None))
print("cuda_avail :", torch.cuda.is_available())

if os.environ.get("ROCM_NUMPY_ABI_REQUIRE_GPU") == "1" and not torch.cuda.is_available():
    raise SystemExit("ERROR: torch.cuda.is_available() is false")

if os.environ.get("ROCM_NUMPY_ABI_EXPECT_TORCHCODEC") == "1":
    import torchcodec
    print("torchcodec :", getattr(torchcodec, "__file__", "unknown"))

if os.environ.get("ROCM_NUMPY_ABI_EXPECT_TORCHAUDIO") == "1":
    import torchaudio
    print("torchaudio :", getattr(torchaudio, "__version__", ""))

print("ABI probe  : OK")
PY
)
