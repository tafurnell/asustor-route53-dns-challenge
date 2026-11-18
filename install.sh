#!/bin/sh
# Installs certbot + the Route 53 DNS plugin into a Python virtual env next to this script.
# The venv lives on /volume1, so it survives reboots. Rerun after ADM or Python3 app updates.
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
VENV="$BASE/venv"

# Prefer the App Central Python3 app, fall back to whatever python3 is on PATH.
PY=/usr/local/AppCentral/python3/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "ERROR: Python 3 not found. Install 'Python3' from App Central first." >&2
  exit 1
fi
echo "Using $PY ($("$PY" --version 2>&1))"

if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating virtual env in $VENV ..."
  if ! "$PY" -m venv "$VENV"; then
    echo "ERROR: could not create a venv with $PY." >&2
    echo "Update the Python3 app in App Central, delete $VENV and try again." >&2
    exit 1
  fi
fi

"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install --upgrade certbot certbot-dns-route53

mkdir -p "$BASE/etc" "$BASE/work" "$BASE/logs"
chmod 700 "$BASE"
chmod 700 "$BASE"/*.sh
[ -f "$BASE/aws-credentials" ] && chmod 600 "$BASE/aws-credentials"

echo
"$VENV/bin/certbot" --version
"$VENV/bin/certbot" plugins --config-dir "$BASE/etc" --work-dir "$BASE/work" --logs-dir "$BASE/logs" 2>/dev/null | grep -A1 "dns-route53" || true
echo
echo "Install complete."
