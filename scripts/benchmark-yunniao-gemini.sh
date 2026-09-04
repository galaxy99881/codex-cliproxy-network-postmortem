#!/usr/bin/env bash

# Enumerate Yunniao nodes and test Gemini eligibility node by node.
# The original GLOBAL selection is restored on exit or interruption.

set -u

CONTROLLER="${CONTROLLER:-http://127.0.0.1:9090}"
PROXY="${PROXY:-http://127.0.0.1:17890}"
GROUP="${GROUP:-GLOBAL}"
SOURCE_GROUP="${SOURCE_GROUP:-🚀 节点选择}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"
CPA_URL="${CPA_URL:-http://127.0.0.1:8317}"
CPA_MODEL="${CPA_MODEL:-gemini-3.7-flash-high}"
CPA_CONFIG="${CPA_CONFIG:-$HOME/Library/Application Support/com.cpa.gui/cpa-core/config.yaml}"
SPEED_BYTES="${SPEED_BYTES:-1000000}"
TIMEOUT="${TIMEOUT:-15}"
LIMIT=0
OUTPUT=""
FORCE=0

usage() {
  printf '%s\n' \
    "Usage: $0 [--limit N] [--output FILE] [--speed-bytes N] [--force]" \
    "" \
    "The script temporarily switches Yunniao's GLOBAL node and always restores it." \
    "Real probes prefer EasyCLIProxyAPI Desktop, then GEMINI_API_KEY." \
    "Without either route, Gemini status is UNVERIFIED." \
    "" \
    "Options:" \
    "  --limit N          Test only the first N real nodes (useful for validation)." \
    "  --output FILE      Save TSV report; default includes current timestamp." \
    "  --speed-bytes N    Bytes downloaded per node; default: 1000000; 0 disables." \
    "  --force            Run even when port 8317 has active clients." \
    "" \
    "Environment: CONTROLLER, PROXY, GROUP, SOURCE_GROUP, GEMINI_MODEL," \
    "             GEMINI_API_KEY, CPA_URL, CPA_MODEL, CPA_CONFIG," \
    "             SPEED_BYTES, TIMEOUT"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --limit) shift; LIMIT="${1:-}" ;;
    --output) shift; OUTPUT="${1:-}" ;;
    --speed-bytes) shift; SPEED_BYTES="${1:-}" ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

for required in curl jq awk sed; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required.\n' "$required" >&2
    exit 2
  }
done

case "$LIMIT" in ''|*[!0-9]*) printf 'ERROR: --limit must be an integer.\n' >&2; exit 2 ;; esac
case "$SPEED_BYTES" in ''|*[!0-9]*) printf 'ERROR: --speed-bytes must be an integer.\n' >&2; exit 2 ;; esac

if [ -z "$OUTPUT" ]; then
  OUTPUT="yunniao-gemini-$(date +%Y%m%d-%H%M%S).tsv"
fi

proxy_data=$(curl --fail --silent --show-error --max-time 5 "$CONTROLLER/proxies") || {
  printf 'ERROR: cannot read Yunniao controller at %s.\n' "$CONTROLLER" >&2
  exit 2
}

original=$(printf '%s' "$proxy_data" | jq -r --arg group "$GROUP" '.proxies[$group].now // empty')
[ -n "$original" ] || {
  printf 'ERROR: cannot determine current selection for group %s.\n' "$GROUP" >&2
  exit 2
}

restore_original() {
  payload=$(jq -nc --arg name "$original" '{name:$name}')
  curl --silent --max-time 5 -X PUT -H 'Content-Type: application/json' \
    --data "$payload" "$CONTROLLER/proxies/$GROUP" >/dev/null 2>&1 || true
}
trap restore_original EXIT INT TERM HUP

cpa_key=""
if [ -r "$CPA_CONFIG" ]; then
  cpa_key=$(awk '
    /^api-keys:/ { in_keys=1; next }
    in_keys && /^[[:space:]]*-[[:space:]]*/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^['"'"'"]|['"'"'"]$/, "", line)
      print line
      exit
    }
    in_keys && /^[^[:space:]]/ { exit }
  ' "$CPA_CONFIG")
fi

cpa_ready=0
if [ -n "$cpa_key" ]; then
  cpa_models=$(curl --silent --show-error --max-time 8 \
    -H "Authorization: Bearer $cpa_key" "$CPA_URL/v1/models" 2>/dev/null || true)
  if printf '%s' "$cpa_models" | jq -e --arg model "$CPA_MODEL" \
    '.data[]? | select(.id == $model)' >/dev/null 2>&1; then
    cpa_ready=1
  fi
fi

active_cpa_clients=0
if command -v lsof >/dev/null 2>&1; then
  active_cpa_clients=$(lsof -nP -iTCP:8317 2>/dev/null \
    | awk 'NR > 1 && $10 == "(ESTABLISHED)" { count++ } END { print count + 0 }')
fi
if [ "$active_cpa_clients" -gt 0 ] && [ "$FORCE" -ne 1 ]; then
  printf 'ERROR: port 8317 has %d active connection(s).\n' "$active_cpa_clients" >&2
  printf 'Pause Claude Code first, or rerun with --force if interruption is acceptable.\n' >&2
  exit 3
fi

nodes=$(printf '%s' "$proxy_data" | jq -r --arg source "$SOURCE_GROUP" '
  . as $root
  | $root.proxies[$source].all[]? as $name
  | ($root.proxies[$name] // {}) as $node
  | select($node.type | IN("Hysteria2", "Vless", "Vmess", "Trojan", "Shadowsocks", "Tuic", "WireGuard"))
  | select($name | test("^(剩余流量|套餐到期|---|官网地址)") | not)
  | [$name, $node.type, ($node.udp // false), ($node.history[-1].delay // 0)]
  | @tsv
')

[ -n "$nodes" ] || {
  printf 'ERROR: no real nodes found in %s.\n' "$SOURCE_GROUP" >&2
  exit 2
}

printf 'node\ttype\tudp\thistory_ms\texit_ip\texit_country\toauth_http\tgemini_http\ttls_ms\tspeed_mbps\treal_gemini\tdetail\n' > "$OUTPUT"

count=0
passed=0
failed=0
unverified=0

printf 'Original node: %s\n' "$original"
printf 'Report: %s\n' "$OUTPUT"
if [ "$cpa_ready" -eq 1 ]; then
  printf 'Real Gemini probe: EasyCLIProxyAPI Desktop (%s)\n' "$CPA_MODEL"
elif [ -n "$GEMINI_API_KEY" ]; then
  printf 'Real Gemini probe: official API (%s)\n' "$GEMINI_MODEL"
else
  printf 'Real Gemini probe: disabled (Desktop route and GEMINI_API_KEY unavailable)\n'
fi

while IFS="$(printf '\t')" read -r node type udp history_ms; do
  [ -n "$node" ] || continue
  count=$((count + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$count" -gt "$LIMIT" ]; then
    break
  fi

  payload=$(jq -nc --arg name "$node" '{name:$name}')
  if ! curl --fail --silent --show-error --max-time 5 -X PUT \
    -H 'Content-Type: application/json' --data "$payload" \
    "$CONTROLLER/proxies/$GROUP" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\t%s\t-\t-\t000\t000\t-\t-\tFAIL\tswitch_failed\n' \
      "$node" "$type" "$udp" "$history_ms" >> "$OUTPUT"
    printf '[%d] FAIL %s (switch failed)\n' "$count" "$node"
    failed=$((failed + 1))
    continue
  fi

  trace=$(curl --proxy "$PROXY" --silent --show-error --max-time "$TIMEOUT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  exit_ip=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1)
  exit_country=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -1)
  [ -n "$exit_ip" ] || exit_ip="-"
  [ -n "$exit_country" ] || exit_country="-"

  oauth_result=$(curl --proxy "$PROXY" --silent --show-error --output /dev/null \
    --max-time "$TIMEOUT" --write-out '%{http_code}' \
    https://oauth2.googleapis.com/ 2>/dev/null || true)
  [ -n "$oauth_result" ] || oauth_result="000"

  gemini_transport=$(curl --proxy "$PROXY" --silent --show-error --output /dev/null \
    --max-time "$TIMEOUT" --write-out '%{http_code}\t%{time_appconnect}' \
    https://generativelanguage.googleapis.com/ 2>/dev/null || true)
  gemini_http=$(printf '%s' "$gemini_transport" | awk -F '\t' '{print $1}')
  tls_seconds=$(printf '%s' "$gemini_transport" | awk -F '\t' '{print $2}')
  [ -n "$gemini_http" ] || gemini_http="000"
  tls_ms=$(awk -v value="${tls_seconds:-0}" 'BEGIN { printf "%.0f", value * 1000 }')

  speed="-"
  if [ "$SPEED_BYTES" -gt 0 ]; then
    speed_bps=$(curl --proxy "$PROXY" --silent --show-error --output /dev/null \
      --max-time 30 --write-out '%{speed_download}' \
      "https://speed.cloudflare.com/__down?bytes=$SPEED_BYTES" 2>/dev/null || true)
    if [ -n "$speed_bps" ] && [ "$speed_bps" != "0" ]; then
      speed=$(awk -v value="$speed_bps" 'BEGIN { printf "%.2f", value * 8 / 1000000 }')
    fi
  fi

  real_status="UNVERIFIED"
  detail="no_api_key"
  if [ "$cpa_ready" -eq 1 ]; then
    response=$(curl --silent --show-error --max-time 50 \
      -H "Authorization: Bearer $cpa_key" \
      -H 'Content-Type: application/json' \
      -X POST --data "{\"model\":\"$CPA_MODEL\",\"input\":\"Reply with exactly OK.\"}" \
      "$CPA_URL/v1/responses" 2>/dev/null || true)
    answer=$(printf '%s' "$response" | jq -r \
      '[.output[]?.content[]?.text // empty] | join("")' 2>/dev/null)
    error_message=$(printf '%s' "$response" | jq -r \
      '.error.message // .error // empty' 2>/dev/null | tr '\t\r\n' ' ' | cut -c 1-140)
    if [ -n "$answer" ]; then
      real_status="PASS"
      detail="desktop_cpa_generated_content"
      passed=$((passed + 1))
    else
      real_status="FAIL"
      detail="${error_message:-desktop_cpa_no_response}"
      failed=$((failed + 1))
    fi
  elif [ -n "$GEMINI_API_KEY" ]; then
    response=$(curl --proxy "$PROXY" --silent --show-error --max-time 40 \
      -H 'Content-Type: application/json' \
      -X POST --data '{"contents":[{"parts":[{"text":"Reply with exactly OK."}]}]}' \
      "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY" \
      2>/dev/null || true)
    answer=$(printf '%s' "$response" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null)
    error_message=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null | tr '\t\r\n' ' ' | cut -c 1-140)
    if [ -n "$answer" ]; then
      real_status="PASS"
      detail="generated_content"
      passed=$((passed + 1))
    else
      real_status="FAIL"
      detail="${error_message:-no_response}"
      failed=$((failed + 1))
    fi
  else
    unverified=$((unverified + 1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$node" "$type" "$udp" "$history_ms" "$exit_ip" "$exit_country" \
    "$oauth_result" "$gemini_http" "$tls_ms" "$speed" "$real_status" "$detail" >> "$OUTPUT"
  printf '[%d] %s  country=%s oauth=%s api=%s tls=%sms speed=%sMbps Gemini=%s\n' \
    "$count" "$node" "$exit_country" "$oauth_result" "$gemini_http" "$tls_ms" "$speed" "$real_status"
done <<EOF
$nodes
EOF

restore_original
trap - EXIT INT TERM HUP

printf '\nTested: %d  PASS: %d  FAIL: %d  UNVERIFIED: %d\n' \
  "$((count > LIMIT && LIMIT > 0 ? LIMIT : count))" "$passed" "$failed" "$unverified"
printf 'Restored node: %s\n' "$original"
printf 'Saved report: %s\n' "$OUTPUT"

if [ "$cpa_ready" -ne 1 ] && [ -z "$GEMINI_API_KEY" ]; then
  printf 'Start EasyCLIProxyAPI Desktop or set GEMINI_API_KEY before claiming support.\n'
fi
