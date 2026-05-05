#!/usr/bin/env bash
# mcp-csi-camera-watchdog.sh
#
# Periodic liveness-probe + escalation ladder for the mcp-csi-camera
# systemd unit. Invoked by mcp-csi-camera-watchdog.timer every 30 s.
#
# Why this exists
# ---------------
# `Restart=on-failure` in the unit catches the easy case (process crashes,
# exits non-zero). It does NOT catch the case we hit on Tegra210: process
# is alive, /mcp endpoint accepts handshakes, but the underlying gstreamer
# pipeline is wedged on `nvbuf_utils: dmabuf_fd -1` (host1x channel stuck)
# and every `view_scene` call returns a 10-second timeout. The HTTP layer
# is happy; the camera is dead. We need an active probe to detect this.
#
# Escalation ladder
# -----------------
# State is held in /run/mcp-csi-camera-watchdog/state (cleared on reboot —
# we want fresh state after a host reboot). Each failed probe bumps state.
#   state 0 -> stage 1: restart mcp-csi-camera (lightest, fixes ~70% of
#              real-world failures: "daemon stuck, just bounce the user
#              process"). Sets state=1.
#   state 1 -> stage 2: also restart nvargus-daemon, then mcp-csi-camera
#              (covers cases where Argus userspace daemon is wedged). Sets
#              state=2.
#   state 2 -> stage 3: full system reboot, rate-limited to once per hour
#              via /var/lib/mcp-csi-camera-watchdog/last-reboot
#              (persistent, intentionally — the cooldown must survive the
#              very reboot it gates). Sets state=3.
#   state 3 -> manual intervention required. We log loudly and stop
#              escalating. (Ribbon oxidation, bad sensor-mode in DTB,
#              hardware death — none of those are software-fixable.)
# A successful probe at any state immediately resets state to 0.
#
# Why root, not sudoers
# ---------------------
# This script needs to call `systemctl restart nvargus-daemon` and `reboot`.
# It runs as root via the watchdog systemd unit (User= unset in
# mcp-csi-camera-watchdog.service). That keeps the sudoers config out of
# the recovery path entirely — fewer moving parts, fewer ways to misconfigure.

set -euo pipefail

# ---------------- config (overridable via /etc/default/mcp-csi-camera-watchdog)

# Endpoint to probe. Default matches the unit's listen=0.0.0.0:8777.
WATCHDOG_HEALTHZ_URL="${WATCHDOG_HEALTHZ_URL:-http://127.0.0.1:8777/healthz}"
# How long to wait for the /healthz response. Server-side probe is ~500 ms;
# this is the network/handshake budget on top.
WATCHDOG_CURL_TIMEOUT_SEC="${WATCHDOG_CURL_TIMEOUT_SEC:-5}"
# Minimum gap between rate-limited reboots. 1 h prevents a genuinely broken
# camera (oxidised ribbon, dead sensor) from ribbon-burning the SD with a
# reboot loop.
WATCHDOG_REBOOT_COOLDOWN_SEC="${WATCHDOG_REBOOT_COOLDOWN_SEC:-3600}"
# Service unit name — exposed for tests / alternative deployments.
WATCHDOG_UNIT="${WATCHDOG_UNIT:-mcp-csi-camera.service}"
WATCHDOG_NVARGUS_UNIT="${WATCHDOG_NVARGUS_UNIT:-nvargus-daemon.service}"

# ---------------- paths

RUN_DIR=/run/mcp-csi-camera-watchdog
STATE_DIR=/var/lib/mcp-csi-camera-watchdog
STATE_FILE="$RUN_DIR/state"
LAST_REBOOT_FILE="$STATE_DIR/last-reboot"

mkdir -p "$RUN_DIR" "$STATE_DIR"

# ---------------- helpers

log() { echo "[watchdog] $*"; }

read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_state() { echo "$1" > "$STATE_FILE"; }

# ---------------- pre-flight: respect a deliberate stop

# If the operator ran `systemctl stop mcp-csi-camera`, we don't want the
# watchdog to fight them by restarting it. `systemctl is-active` returns
# "active", "activating", "inactive", "deactivating", "failed", or "unknown".
unit_state="$(systemctl is-active "$WATCHDOG_UNIT" 2>/dev/null || true)"
case "$unit_state" in
  inactive|deactivating)
    log "$WATCHDOG_UNIT is $unit_state (deliberately stopped) — skipping probe"
    exit 0
    ;;
  activating)
    # Pipeline warmup is ~1 s; if we hit during that window, skip rather
    # than declare failure prematurely.
    log "$WATCHDOG_UNIT is activating — skipping probe"
    exit 0
    ;;
esac

# ---------------- probe

# `--max-time` covers the whole curl invocation (DNS + connect + TLS + body).
http_status="$(curl -s -o /dev/null \
  --max-time "$WATCHDOG_CURL_TIMEOUT_SEC" \
  -w '%{http_code}' \
  "$WATCHDOG_HEALTHZ_URL" 2>/dev/null || echo 000)"

state="$(read_state)"

if [[ "$http_status" == "200" ]]; then
  # Healthy. Reset state on recovery so a fresh future failure starts at
  # stage 1 again, not picks up where we left off.
  if [[ "$state" != "0" ]]; then
    log "/healthz OK (was state=$state) — clearing escalation"
    write_state 0
  fi
  exit 0
fi

log "/healthz failed (http=$http_status state=$state unit=$unit_state) — escalating"

# ---------------- escalation ladder

case "$state" in
  0)
    log "stage 1: systemctl restart $WATCHDOG_UNIT"
    if ! systemctl restart "$WATCHDOG_UNIT"; then
      log "stage 1 restart returned non-zero — unit may be in failed state"
    fi
    write_state 1
    ;;
  1)
    log "stage 2: systemctl restart $WATCHDOG_NVARGUS_UNIT + $WATCHDOG_UNIT"
    if ! systemctl restart "$WATCHDOG_NVARGUS_UNIT"; then
      log "stage 2 nvargus restart failed (continuing anyway)"
    fi
    # Brief pause so nvargus-daemon is actually accepting connections by
    # the time the camera unit's pipeline tries to connect to it.
    sleep 2
    if ! systemctl restart "$WATCHDOG_UNIT"; then
      log "stage 2 mcp restart returned non-zero"
    fi
    write_state 2
    ;;
  2)
    now="$(date +%s)"
    last_reboot=0
    if [[ -f "$LAST_REBOOT_FILE" ]]; then
      last_reboot="$(cat "$LAST_REBOOT_FILE" 2>/dev/null || echo 0)"
    fi
    age=$(( now - last_reboot ))

    if (( age < WATCHDOG_REBOOT_COOLDOWN_SEC )); then
      log "stage 3: reboot wanted but rate-limited (last reboot ${age}s ago, cooldown ${WATCHDOG_REBOOT_COOLDOWN_SEC}s) — MANUAL INTERVENTION REQUIRED"
      log "    diagnose with: journalctl -u $WATCHDOG_UNIT --since '5 min ago'"
      log "    and:           dmesg | grep -iE 'imx219|isp|nvbuf|argus' | tail -20"
      write_state 3
    else
      log "stage 3: rebooting host (last reboot ${age}s ago, exceeds cooldown ${WATCHDOG_REBOOT_COOLDOWN_SEC}s)"
      echo "$now" > "$LAST_REBOOT_FILE"
      write_state 3
      sync
      # `systemctl reboot` is the systemd-native form; equivalent to
      # /sbin/reboot but goes through systemd's shutdown sequencing so
      # journald flushes cleanly.
      systemctl reboot
    fi
    ;;
  3)
    log "stage 3 already exhausted — refusing further automated escalation"
    log "    diagnose with: journalctl -u $WATCHDOG_UNIT --since '5 min ago'"
    log "    and:           dmesg | grep -iE 'imx219|isp|nvbuf|argus' | tail -20"
    log "    once fixed:    rm $STATE_FILE  (or reboot to clear)"
    ;;
  *)
    log "unknown state=$state — resetting to 0"
    write_state 0
    ;;
esac

# Non-zero exit so the timer's invocation shows up in `journalctl` as a
# warning rather than blending into routine "OK" runs.
exit 1
