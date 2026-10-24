#!/usr/bin/env bash
# Remove rime-cloud from a fcitx5-rime user profile.
set -euo pipefail

RIME_DIR="${RIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime}"
SCHEMA="${SCHEMA:-rime_ice}"
DO_DEPLOY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rime-dir) RIME_DIR="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --no-deploy) DO_DEPLOY=0; shift ;;
    -h|--help) echo "usage: $0 [--rime-dir DIR] [--schema NAME] [--no-deploy]"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
RIME_DIR="${RIME_DIR/#\~/$HOME}"
CUSTOM="$RIME_DIR/$SCHEMA.custom.yaml"

rm -f "$RIME_DIR/lua/cloud_input.lua"
rm -rf "$RIME_DIR/lua/cloud_input"

if [[ -f "$CUSTOM" ]]; then
  python3 - "$CUSTOM" <<'PY'
import sys
path = sys.argv[1]
START = "  # >>> rime-cloud managed block (do not edit inside) >>>"
END = "  # <<< rime-cloud managed block <<<"
with open(path, encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)
out, skip = [], False
for line in lines:
    if line.rstrip("\n") == START:
        skip = True
        continue
    if line.rstrip("\n") == END and skip:
        skip = False
        continue
    if not skip:
        out.append(line)
with open(path, "w", encoding="utf-8") as f:
    f.write("".join(out))
print("removed rime-cloud block from " + path)
PY
fi

if [[ "$DO_DEPLOY" == 1 ]] && command -v rime_deployer >/dev/null 2>&1; then
  rime_deployer --build "$RIME_DIR" "${RIME_SHARED_DIR:-/usr/share/rime-data}" || true
  if command -v fcitx5-remote >/dev/null 2>&1 && fcitx5-remote --check >/dev/null 2>&1; then
    fcitx5-remote -r >/dev/null 2>&1 || true
  fi
fi
echo "rime-cloud uninstalled."
