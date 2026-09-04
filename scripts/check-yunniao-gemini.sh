#!/usr/bin/env bash

# Read-only health check for Yunniao -> CLIProxyAPI -> Gemini.
# It never changes proxy selection, TUN state, credentials, or services.

set -u

CONTROLLER="${CONTROLLER:-http://127.0.0.1:9090}"
PROXY="${PROXY:-http://127.0.0.1:17890}"
BRIDGE="${BRIDGE:-http://127.0.0.1:8318}"
MODEL="${MODEL:-gemini-3.7-flash-high}"
SPEED_BYTES="${SPEED_BYTES:-5000000}"
TIMEOUT="${TIMEOUT:-15}"
FULL=0

usage() {
  printf '%s\n' \
    "Usage: $0 [--full] [--bytes N]" \
    "" \
    "Default mode performs only network and route checks." \
    "--full      Also run an ephemeral Codex model probe (uses a small amount of quota)." \
    "--bytes N   Download size for speed test; default: 5000000." \
    "" \
    "Environment overrides: CONTROLLER, PROXY, BRIDGE, MODEL, SPEED_BYTES, TIMEOUT"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --bytes)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      SPEED_BYTES="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if ! command -v curl >/dev/null 2>&1; then
  printf 'ERROR: curl is required.\n' >&2
  exit 2
fi

pass=0
fail=0
warn=0

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$*"; }
note() { warn=$((warn + 1)); printf 'WARN  %s\n' "$*"; }

heading() {
  printf '\n== %s ==\n' "$1"
}

port_check() {
  label="$1"
  host="$2"
  port="$3"
  if nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
    ok "$label is listening at $host:$port"
  else
    bad "$label is not listening at $host:$port"
  fi
}

url_check() {
  label="$1"
  url="$2"
  result=$(curl --proxy "$PROXY" --silent --show-error --output /dev/null \
    --max-time "$TIMEOUT" \
    --write-out '%{http_code}\t%{time_connect}\t%{time_appconnect}\t%{time_total}' \
    "$url" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    code=$(printf '%s' "$result" | awk -F '\t' '{print $1}')
    connect=$(printf '%s' "$result" | awk -F '\t' '{print $2}')
    tls=$(printf '%s' "$result" | awk -F '\t' '{print $3}')
    total=$(printf '%s' "$result" | awk -F '\t' '{print $4}')
    if [ "$code" != "000" ]; then
      ok "$label reachable (HTTP $code, connect ${connect}s, TLS ${tls}s, total ${total}s)"
    else
      bad "$label returned no HTTP response"
    fi
  else
    reason=$(printf '%s' "$result" | head -1 | sed -E 's/[[:space:]]+/ /g')
    bad "$label unreachable ($reason)"
  fi
}

heading "Local services"
port_check "Yunniao proxy" "127.0.0.1" "17890"
port_check "Yunniao controller" "127.0.0.1" "9090"
port_check "CLIProxyAPI" "127.0.0.1" "8317"
port_check "Codex transparent bridge" "127.0.0.1" "8318"

heading "Current Yunniao route"
if command -v jq >/dev/null 2>&1; then
  proxy_json=$(curl --silent --show-error --max-time 4 "$CONTROLLER/proxies" 2>/dev/null || true)
  config_json=$(curl --silent --show-error --max-time 4 "$CONTROLLER/configs" 2>/dev/null || true)
  selected=$(printf '%s' "$proxy_json" | jq -r '.proxies.GLOBAL.now // .proxies["🚀 节点选择"].now // empty' 2>/dev/null)
  mode=$(printf '%s' "$config_json" | jq -r '.mode // empty' 2>/dev/null)
  tun=$(printf '%s' "$config_json" | jq -r '.tun.enable // false' 2>/dev/null)
  [ -n "$selected" ] && printf 'Node: %s\n' "$selected" || note "cannot read selected node"
  [ -n "$mode" ] && printf 'Mode: %s\n' "$mode" || note "cannot read proxy mode"
  printf 'TUN:  %s\n' "$tun"
else
  note "jq is unavailable; skipping controller details"
fi

heading "Google and Gemini connectivity through Yunniao"
url_check "Google OAuth" "https://oauth2.googleapis.com/"
url_check "Gemini API" "https://generativelanguage.googleapis.com/"
url_check "Google API front door" "https://www.googleapis.com/"

heading "Download speed through current node"
speed_result=$(curl --proxy "$PROXY" --silent --show-error --output /dev/null \
  --max-time 30 \
  --write-out '%{size_download}\t%{time_total}\t%{speed_download}' \
  "https://speed.cloudflare.com/__down?bytes=$SPEED_BYTES" 2>&1)
speed_status=$?
if [ "$speed_status" -eq 0 ]; then
  downloaded=$(printf '%s' "$speed_result" | awk -F '\t' '{print $1}')
  elapsed=$(printf '%s' "$speed_result" | awk -F '\t' '{print $2}')
  bytes_per_second=$(printf '%s' "$speed_result" | awk -F '\t' '{print $3}')
  mbps=$(awk -v value="$bytes_per_second" 'BEGIN { printf "%.2f", value * 8 / 1000000 }')
  ok "downloaded $downloaded bytes in ${elapsed}s (${mbps} Mbps)"
else
  bad "speed test failed ($(printf '%s' "$speed_result" | head -1))"
fi

heading "CLIProxyAPI model route"
health=$(curl --silent --show-error --max-time 4 "$BRIDGE/__codex_bridge_health" 2>/dev/null || true)
if printf '%s' "$health" | grep -q '"status":"ok"'; then
  ok "transparent bridge health endpoint"
else
  bad "transparent bridge health endpoint"
fi

models=$(curl --silent --show-error --max-time 8 "$BRIDGE/v1/models" 2>/dev/null || true)
if command -v jq >/dev/null 2>&1 && printf '%s' "$models" | jq -e --arg model "$MODEL" '.data[]? | select(.id == $model)' >/dev/null 2>&1; then
  ok "$MODEL is present in live /v1/models"
elif printf '%s' "$models" | grep -Fq "\"$MODEL\""; then
  ok "$MODEL is present in live /v1/models"
else
  bad "$MODEL is missing from live /v1/models"
fi

heading "Gemini credential egress"
credential_route=""
if command -v jq >/dev/null 2>&1; then
  for credential_file in "$HOME"/.cli-proxy-api/*.json; do
    [ -f "$credential_file" ] || continue
    route=$(jq -r 'select(.type == "antigravity" and .disabled != true) | .proxy_url // "DIRECT"' "$credential_file" 2>/dev/null)
    if [ -n "$route" ]; then
      credential_route="$route"
      break
    fi
  done
fi

if [ -z "$credential_route" ]; then
  note "cannot determine the active Gemini credential route"
elif [ "$credential_route" = "$PROXY" ]; then
  ok "Gemini credential uses the tested Yunniao proxy ($credential_route)"
else
  note "Gemini credential uses $credential_route, not the tested Yunniao proxy $PROXY"
  printf '      Network checks above passed through Yunniao, but --full will follow the credential route.\n'
fi

if [ "$FULL" -eq 1 ]; then
  heading "End-to-end Codex probe"
  BRIDGE_TOOL="$HOME/.agents/skills/codex-cli-model-bridge/scripts/bridge.py"
  if [ -f "$BRIDGE_TOOL" ] && command -v python3 >/dev/null 2>&1; then
    if python3 "$BRIDGE_TOOL" probe --desktop --models "$MODEL"; then
      ok "Codex completed a real $MODEL request"
    else
      bad "Codex could not complete a real $MODEL request"
    fi
  else
    bad "model bridge probe tool is unavailable"
  fi
else
  printf 'SKIP  real model request; rerun with --full to test it.\n'
fi

heading "Summary"
printf 'PASS=%d  WARN=%d  FAIL=%d\n' "$pass" "$warn" "$fail"
if [ "$fail" -eq 0 ]; then
  printf 'Result: current node passed all selected checks.\n'
  exit 0
fi
printf 'Result: one or more checks failed; do not treat the current node as stable for Gemini.\n'
exit 1
