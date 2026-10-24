#!/usr/bin/env bash
# Resolve shouji.sogou.com through public DoH and print a comma-separated IP
# list suitable for cloud_input/sogou_ips (some ISPs filter this hostname).
set -euo pipefail

query() {
  local url="$1"
  curl -fsS -H 'accept: application/dns-json' "$url" 2>/dev/null
}

json="$(query 'https://cloudflare-dns.com/dns-query?name=shouji.sogou.com&type=A')" || \
json="$(query 'https://dns.google/resolve?name=shouji.sogou.com&type=A')" || {
  echo "error: DoH lookup failed" >&2
  exit 1
}

printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
ips = [a["data"] for a in data.get("Answer", []) if a.get("type") == 1]
print(",".join(ips))
'
