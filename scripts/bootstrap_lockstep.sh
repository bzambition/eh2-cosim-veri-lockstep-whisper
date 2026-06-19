#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Reproducible entry point for the lockstep-Whisper flow.
# Machine-specific paths live in env.mk. See env.mk.example and
# docs/lockstep_whisper_phase0b.md for the toolchain/Boost setup.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f env.mk ]]; then
  echo "ERROR: env.mk not found. Run: cp env.mk.example env.mk"
  echo "Then set CAC_CXX, WHISPER_CXX, WHISPER_BOOST_ROOT, and simulator/tool paths for this machine."
  exit 1
fi

# env.mk is Make syntax, not necessarily valid shell syntax. Export the simple
# VAR = value / VAR := value / VAR ?= value assignments used by this flow so
# child processes can find compiler/runtime libraries, while make still reads
# env.mk directly.
while IFS= read -r assignment; do
  [[ -n "${assignment}" ]] || continue
  name="${assignment%%=*}"
  value="${assignment#*=}"
  name="${name%"${name##*[![:space:]]}"}"
  name="${name%"${name##*[!:?[:space:]]}"}"
  name="${name%%[:? ]*}"
  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  export "${name}=${value}"
done < <(grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:?]?=' env.mk)

make whisper
make cac
make smoke LOCKSTEP_WHISPER=1
