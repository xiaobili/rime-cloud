#!/usr/bin/env bash
# Install rime-cloud into an fcitx5-rime user profile.
#
#   ./install.sh                     # ~/.local/share/fcitx5/rime, schema rime_ice
#   ./install.sh --rime-dir DIR      # custom profile (also useful for tests)
#   ./install.sh --schema double_pinyin --no-deploy
#
# The installer backs up the schema's *.custom.yaml before changing it and
# writes a clearly marked managed block; uninstall.sh removes exactly that
# block.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RIME_DIR="${RIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime}"
SCHEMA="${SCHEMA:-rime_ice}"
DO_DEPLOY=1
DO_BUILD=1
FORCE=0

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Install rime-cloud into an fcitx5-rime user profile.

  ./install.sh                     # ~/.local/share/fcitx5/rime, schema rime_ice
  ./install.sh --rime-dir DIR      # custom profile (also useful for tests)
  ./install.sh --schema double_pinyin --no-deploy

Options:
  --rime-dir DIR   Rime user data directory
  --schema NAME    schema id to patch (default: rime_ice)
  --no-deploy      only install files and patch YAML
  --no-build       do not compile the optional C HTTP module
  --force          patch even if cloud_input keys already exist
  -h, --help       show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rime-dir) RIME_DIR="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --no-deploy) DO_DEPLOY=0; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RIME_DIR="${RIME_DIR/#\~/$HOME}"
CUSTOM="$RIME_DIR/$SCHEMA.custom.yaml"

if [[ ! -d "$RIME_DIR" ]]; then
  echo "error: Rime user directory not found: $RIME_DIR" >&2
  echo "Start fcitx5-rime once, or pass --rime-dir." >&2
  exit 1
fi

if ! command -v rime_deployer >/dev/null 2>&1; then
  echo "warning: rime_deployer not found; deployment will be skipped." >&2
  DO_DEPLOY=0
fi

echo "== rime-cloud installer"
echo "   profile : $RIME_DIR"
echo "   schema  : $SCHEMA"

# ---------------------------------------------------------------------------
# 1. Build the optional C HTTP module.  The plugin has a pure-Lua curl
#    fallback, so a build failure is not fatal.
# ---------------------------------------------------------------------------
if [[ "$DO_BUILD" == 1 ]]; then
  if command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; then
    if make -C "$ROOT" lua/cloud_input/cloud_http.so >/tmp/rime-cloud-build.log 2>&1; then
      echo "   http    : C module built"
    else
      echo "warning: C module build failed; using the curl fallback." >&2
      echo "         see /tmp/rime-cloud-build.log" >&2
      rm -f "$ROOT/lua/cloud_input/cloud_http.so"
    fi
  else
    echo "warning: no C compiler; using the curl fallback." >&2
  fi
else
  echo "   http    : build skipped (--no-build)"
fi

# ---------------------------------------------------------------------------
# 2. Install Lua files.
# ---------------------------------------------------------------------------
mkdir -p "$RIME_DIR/lua"
rm -rf "$RIME_DIR/lua/cloud_input"
cp -a "$ROOT/lua/cloud_input" "$RIME_DIR/lua/cloud_input"
cp -a "$ROOT/lua/cloud_input.lua" "$RIME_DIR/lua/cloud_input.lua"
echo "   lua     : installed to $RIME_DIR/lua/cloud_input*"

# ---------------------------------------------------------------------------
# 3. Patch the schema's custom YAML with a managed block.
# ---------------------------------------------------------------------------
python3 - "$CUSTOM" "$FORCE" <<'PY'
import os
import shutil
import sys
import time

path, force = sys.argv[1], sys.argv[2] == "1"
START = "  # >>> rime-cloud managed block (do not edit inside) >>>"
END = "  # <<< rime-cloud managed block <<<"
BLOCK = """\
  # >>> rime-cloud managed block (do not edit inside) >>>
  engine/processors/@next: lua_processor@*cloud_input*processor
  engine/translators/@next: lua_translator@*cloud_input*translator
  engine/filters/@next: lua_filter@*cloud_input*filter
  cloud_input:
    provider: auto
    auto_hotword: true
    auto_completion: true
    auto_wait_ms: 220
    weak_quality: 1.5
    wait_min_length: 4
    auto_known: false
    timeout_ms: 1200
    # Sogou's hostname is filtered by some ISPs.  Current public IPs are used
    # by default; set to "" to use system DNS, or "doh" for Cloudflare DoH.
    # sogou_ips: "129.226.102.244,129.226.103.145"
  # <<< rime-cloud managed block <<<
"""

old = None
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        old = f.read()

if old is None:
    new = "patch:\n" + BLOCK
else:
    lines = old.splitlines(keepends=True)
    start = end = None
    for i, line in enumerate(lines):
        if line.rstrip("\n") == START:
            start = i
        elif line.rstrip("\n") == END and start is not None:
            end = i
            break
    if start is not None and end is not None:
        new = "".join(lines[:start]) + BLOCK + "".join(lines[end + 1:])
    else:
        if "cloud_input:" in old and not force:
            sys.exit("error: %s already contains a cloud_input section but no "
                     "rime-cloud marker block. Re-run with --force after "
                     "checking it." % path)
        patch_line = None
        for i, line in enumerate(lines):
            if line.rstrip("\n") == "patch:":
                patch_line = i
                break
        if patch_line is None:
            if old and not old.endswith("\n"):
                old += "\n"
            new = old + "\npatch:\n" + BLOCK
        else:
            new = "".join(lines[:patch_line + 1]) + BLOCK + "".join(lines[patch_line + 1:])

if old is not None:
    backup = path + ".rime-cloud.bak." + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, backup)
    print("   backup  : " + backup)
with open(path, "w", encoding="utf-8") as f:
    f.write(new)
print("   schema  : patched " + path)
PY

# ---------------------------------------------------------------------------
# 4. Deploy.
# ---------------------------------------------------------------------------
if [[ "$DO_DEPLOY" == 1 ]]; then
  SHARED="${RIME_SHARED_DIR:-/usr/share/rime-data}"
  echo "== deploying Rime schemas"
  if ! rime_deployer --build "$RIME_DIR" "$SHARED"; then
    echo "warning: rime_deployer failed. Restart fcitx5 and trigger a Rime" >&2
    echo "         deployment manually (or run rime_deployer again)." >&2
  fi
  if command -v fcitx5-remote >/dev/null 2>&1 && fcitx5-remote --check >/dev/null 2>&1; then
    fcitx5-remote -r >/dev/null 2>&1 || true
    echo "   note    : fcitx5 is running; if candidates do not appear, restart fcitx5"
  fi
fi

cat <<EOF

Installed. Next steps:
  1. Make sure fcitx5 is running (fcitx5 -d) and fcitx5-rime is the active IME.
  2. Type a pinyin string.  🔥 = cloud hot word, ✨ = cloud completion.
  3. Press Control+t while composing to force a manual cloud query.
  4. See README.md for configuration and troubleshooting.
EOF
