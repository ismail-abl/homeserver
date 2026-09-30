#!/usr/bin/env bash
# Create (or refresh) the Python venv that holds Ansible, from WSL or any Linux.
#
#   ./setup-linux.sh             create if missing, install requirements.txt
#   ./setup-linux.sh --recreate  delete the venv first
#
# The venv lives outside the repo (default ~/.venvs/homeserver) to prevent
# syncing tools or IDEs from processing thousands of venv files and
# mangling symlinks. Override with VENV_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${VENV_DIR:-$HOME/.venvs/homeserver}"
PYTHON_CMD="${PYTHON_CMD:-python3}"

if ! command -v "$PYTHON_CMD" >/dev/null 2>&1; then
  echo "Error: $PYTHON_CMD not found in PATH (Debian/Ubuntu: apt install python3-venv)." >&2
  exit 1
fi

if [[ "${1:-}" == "--recreate" && -d "$VENV_DIR" ]]; then
  echo "Removing existing virtual environment at $VENV_DIR"
  rm -rf "$VENV_DIR"
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "Creating virtual environment at $VENV_DIR"
  mkdir -p "$(dirname "$VENV_DIR")"
  "$PYTHON_CMD" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip
"$VENV_DIR/bin/python" -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"

"$VENV_DIR/bin/ansible" --version | head -1
echo

if [[ -f "$SCRIPT_DIR/requirements.yml" ]]; then
  echo "Installing Ansible collections/roles from requirements.yml..."
  "$VENV_DIR/bin/ansible-galaxy" install -r "$SCRIPT_DIR/requirements.yml"
fi

echo "Ready. Activate with: source $VENV_DIR/bin/activate"
