#!/bin/zsh
# Starts the local Parakeet Redux server. First run creates a virtualenv and installs moondream.
set -e
cd "$(dirname "$0")"
VENV="${PARAKEET_VENV:-$HOME/VoxOS-Dependencies/parakeet-env}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating virtualenv at $VENV…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet -r requirements.txt
fi
exec "$VENV/bin/python" -I server.py "$@"
