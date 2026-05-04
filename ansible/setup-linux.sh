#!/usr/bin/env bash

# linux as it can directly run ansible
# if not already done create venv
# if not already done get into venv
# if not already done install requirements.txt
# be ready to type ansible commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"

PYTHON_CMD="${PYTHON_CMD:-python3}"

if ! command -v "$PYTHON_CMD" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_CMD="python"
  else
    echo "Error: python3 (or python) is required but was not found in PATH."
    exit 1
  fi
fi

if [[ "${1:-}" == "--recreate" && -d "$VENV_DIR" ]]; then
  echo "Removing existing virtual environment at $VENV_DIR"
  rm -rf "$VENV_DIR"
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  echo "Creating virtual environment with '$PYTHON_CMD'"
  "$PYTHON_CMD" -m venv "$VENV_DIR"
fi

if ! "$VENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
  echo "Bootstrapping pip in the virtual environment"
  "$VENV_DIR/bin/python" -m ensurepip --upgrade
fi

echo "Installing Python dependencies from requirements.txt"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$PROJECT_DIR/requirements.txt"

if [[ -x "$VENV_DIR/bin/adt" ]]; then
  echo "Ansible Dev Tools version:"
  "$VENV_DIR/bin/adt" --version
fi

echo
echo "Setup complete. Activate with: source .venv/bin/activate"
