#!/usr/bin/env bash
# End-to-end test: install into a copy of the live Rime profile, deploy, and
# type keys through a headless librime session.  Requires network access to
# the cloud endpoints.
#
#   ./tests/integration.sh
#   RIME_DIR=/path/to/profile ./tests/integration.sh
#   KEEP=1 ./tests/integration.sh        # keep build/integration-rime
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="${RIME_DIR:-$HOME/.local/share/fcitx5/rime}"
WORK="${WORK_DIR:-$ROOT/build/integration-rime}"

if [[ ! -d "$LIVE" ]]; then
  echo "skip: no Rime profile at $LIVE" >&2
  exit 0
fi
if ! command -v rime_deployer >/dev/null 2>&1; then
  echo "skip: rime_deployer not installed" >&2
  exit 0
fi

echo "== preparing $WORK"
rm -rf "$WORK"
mkdir -p "$(dirname "$WORK")"
cp -a "$LIVE" "$WORK"
rm -rf "$WORK"/sync "$WORK"/*.userdb 2>/dev/null || true

"$ROOT/install.sh" --rime-dir "$WORK" --no-deploy >/dev/null
rime_deployer --build "$WORK" /usr/share/rime-data

cc -O2 -o "$ROOT/tests/rime_dump" "$ROOT/tests/rime_dump.c" -lrime

run_keys() {
  timeout 60 env RIME_USER_DIR="$WORK" "$ROOT/tests/rime_dump" rime_ice "$1" 120 2>/dev/null
}

fail=0
check_cloud() {
  local keys="$1" want="$2" label="$3"
  local out
  out="$(run_keys "$keys")"
  if grep -q "$want" <<<"$out"; then
    echo "ok   $label"
    sed -n '/after keys/,$p' <<<"$out" | head -6 | sed 's/^/     /'
  else
    echo "FAIL $label (no '$want' in output)"
    sed -n '/after keys/,$p' <<<"$out" | head -8 | sed 's/^/     /'
    fail=1
  fi
}

# walikun: the local dictionary only offers nonsense (瓦砾困), so the cloud
# hot-word hint should be promoted.
check_cloud "walikun" "🔥" "automatic hot-word hint (walikun)"

# qwer: the local dictionary only has a near-miss (气味儿); the cloud
# expansion (曲蔚然/犬瘟热) exercises the automatic completion path.
check_cloud "qwer" "✨" "automatic completion hint (qwer)"

# Manual trigger must place cloud candidates first.
out="$(run_keys 'nsdd|')"
first="$(sed -n '/after keys/,$p' <<<"$out" | sed -n '2p')"
if grep -qE '🔥|✨' <<<"$first"; then
  echo "ok   manual trigger puts cloud first"
  echo "     $first"
else
  echo "FAIL manual trigger (first candidate: $first)"
  fail=1
fi

if [[ "${KEEP:-0}" != 1 ]]; then
  rm -rf "$WORK"
fi

if [[ "$fail" != 0 ]]; then
  echo "integration test failed" >&2
  exit 1
fi
echo "integration test passed"
