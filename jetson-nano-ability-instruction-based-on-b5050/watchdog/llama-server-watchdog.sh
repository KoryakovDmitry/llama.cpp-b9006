#!/usr/bin/env bash
# llama-server-watchdog.sh
#
# Periodic liveness probe for llama-server.service. Triggered by
# llama-server-watchdog.timer every 30 s.
#
# Why this exists, given Restart=on-failure already covers crashes:
# llama-server can hang while the OS still considers the process healthy
# — stuck inference, deadlock in the multimodal preprocess path, KV-cache
# allocation wedged after an OOM-neighbour. systemd sees a live PID and
# does nothing. We need an active probe.
#
# Why it's much simpler than the mcp-csi-camera watchdog: llama-server is
# stateless. Restart fixes all software-recoverable failures, and there
# is no "kernel host1x channel stuck" failure mode to escalate to a
# host reboot. So no state machine, no rate-limiting — just one rule:
# /health doesn't say ok -> restart.
#
# /health response contract (llama.cpp HTTP server):
#   200  {"status":"ok"}                    -> healthy
#   503  {"error":"Loading model",...}      -> still loading, give it time
#   any other / no response                 -> dead, restart

set -euo pipefail

UNIT="${LLAMA_WATCHDOG_UNIT:-llama-server.service}"
URL="${LLAMA_WATCHDOG_URL:-http://127.0.0.1:8776/health}"
CURL_TIMEOUT="${LLAMA_WATCHDOG_CURL_TIMEOUT_SEC:-5}"

log() { echo "[llama-watchdog] $*"; }

# Respect a deliberate `systemctl stop` — don't fight the operator.
unit_state="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
case "$unit_state" in
  inactive|deactivating)
    log "$UNIT is $unit_state (deliberately stopped) — skipping probe"
    exit 0
    ;;
esac

# Fetch into a temp body so we can branch on both HTTP status and content.
# `--max-time` covers the whole curl call. On connection failure curl
# exits non-zero and we coerce the status to 000.
body="$(mktemp)"
trap 'rm -f "$body"' EXIT

http_code="$(curl -s -o "$body" -m "$CURL_TIMEOUT" -w '%{http_code}' "$URL" 2>/dev/null || echo 000)"

case "$http_code" in
  200)
    # Sanity-check the body too — a misconfigured reverse proxy could
    # send 200 with garbage. We expect llama.cpp's exact "status":"ok".
    if grep -q '"status":"ok"' "$body"; then
      exit 0
    fi
    log "/health returned 200 but body is unexpected ($(head -c 200 "$body")) — restarting $UNIT"
    systemctl restart "$UNIT"
    exit 1
    ;;
  503)
    # llama.cpp explicitly returns 503 during model load. Don't interfere
    # — model loading on a Nano takes 10-30 s and a restart here would
    # just throw away the in-progress load and start over forever.
    log "/health 503 (loading model) — skipping"
    exit 0
    ;;
  000|"")
    log "/health unreachable (curl failed, unit=$unit_state) — restarting $UNIT"
    systemctl restart "$UNIT"
    exit 1
    ;;
  *)
    log "/health returned http=$http_code (body: $(head -c 200 "$body")) — restarting $UNIT"
    systemctl restart "$UNIT"
    exit 1
    ;;
esac
