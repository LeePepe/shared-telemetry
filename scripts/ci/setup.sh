#!/usr/bin/env bash
# Toolchain setup for scripts/verify, used by CI before every lane and once per
# local clone. Creates .venv (gitignored) with the Python SDK dev extra and the
# project-analyzer requirements; in GitHub Actions it also puts .venv on PATH
# and selects the newest installed Xcode on macOS runners.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
python="${PYTHON:-python3}"

"$python" -m venv .venv
.venv/bin/python -m pip install --quiet --upgrade pip
.venv/bin/python -m pip install --quiet -e 'sdks/python[dev]' -r agents/project-analyzer/requirements.txt

if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$root/.venv/bin" >> "$GITHUB_PATH"
    if [ "$(uname -s)" = "Darwin" ]; then
        latest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort -V | tail -1 || true)"
        if [ -n "$latest" ]; then sudo xcode-select -s "$latest"; fi
        swift --version
    fi
fi
echo "[setup] ok: $(.venv/bin/python --version)"
