#!/usr/bin/env bash
# install.sh — deploy the systemd units, watchdog timer, and (optional)
# sudoers file under jetson-nano-ability-instruction-based-on-b5050/
# systemd/ to /etc/systemd/system/ etc.
#
# Run with sudo. The script:
#   1. validates the user, repo root, and llama-server binary path;
#   2. substitutes @@PLACEHOLDERS@@ in *.in templates into rendered units;
#   3. installs them under /etc/systemd/system/;
#   4. creates /etc/default/{mcp-csi-camera,llama-server} if missing
#      (skips if the file already exists — never clobber user config);
#   5. daemon-reloads, enables, and starts the units.
#
# Usage:
#   sudo ./install.sh                         # auto-detect everything
#   sudo ./install.sh --user diikorr \
#                     --repo-root /home/diikorr/llama.cpp-b9006 \
#                     --llama-bin /home/diikorr/.local/bin/rllama-server
#   sudo ./install.sh --with-sudoers          # also deploy optional sudoers
#   sudo ./install.sh --dry-run               # print the rendered files
#   sudo ./install.sh --uninstall             # disable + remove units

set -euo pipefail

# ---------------- arg parsing

USER_NAME=""
REPO_ROOT=""
LLAMA_BIN=""
WITH_SUDOERS=0
DRY_RUN=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)         USER_NAME="$2"; shift 2 ;;
    --repo-root)    REPO_ROOT="$2"; shift 2 ;;
    --llama-bin)    LLAMA_BIN="$2"; shift 2 ;;
    --with-sudoers) WITH_SUDOERS=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    -h|--help)
      sed -n '2,/^set -/p' "$0" | sed 's/^# \?//;$d'
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

# ---------------- defaults

# `realpath` traverses symlinks; safe to call even if SCRIPT_DIR is itself
# inside a symlinked tree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# install.sh lives at <repo>/jetson-nano-...../systemd/install.sh, so two
# `dirname`s up gets us to <repo>/jetson-nano-..... and one more up gets
# us to <repo>. The unit templates expect the latter (without the inner
# directory) so they can compose the full path themselves.
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
USER_NAME_DEFAULT="${SUDO_USER:-${USER:-root}}"

[[ -z "$USER_NAME"  ]] && USER_NAME="$USER_NAME_DEFAULT"
[[ -z "$REPO_ROOT"  ]] && REPO_ROOT="$REPO_ROOT_DEFAULT"

if [[ -z "$LLAMA_BIN" ]]; then
  # Try the user's PATH first (via su -l so we pick up their .profile),
  # fall back to the conventional symlink path from INSTALL.md §6.
  LLAMA_BIN="$(su -l "$USER_NAME" -c 'command -v rllama-server' 2>/dev/null || true)"
  [[ -z "$LLAMA_BIN" ]] && LLAMA_BIN="/home/$USER_NAME/.local/bin/rllama-server"
fi

# ---------------- validation

if [[ "$EUID" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  echo "must be root (use sudo) — pass --dry-run to preview without root" >&2
  exit 1
fi

if ! id "$USER_NAME" >/dev/null 2>&1; then
  echo "user does not exist: $USER_NAME" >&2
  exit 1
fi

if [[ "$UNINSTALL" -eq 0 ]]; then
  if [[ ! -d "$REPO_ROOT/jetson-nano-ability-instruction-based-on-b5050" ]]; then
    echo "repo root looks wrong: $REPO_ROOT (expected jetson-nano-... subdir inside)" >&2
    exit 1
  fi
  MCP_BIN="$REPO_ROOT/jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera/target/release/mcp-csi-camera"
  if [[ ! -x "$MCP_BIN" ]]; then
    echo "WARNING: mcp-csi-camera binary not found at $MCP_BIN" >&2
    echo "         build it first:  cd $REPO_ROOT/jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera && cargo build --release" >&2
    echo "         continuing — the unit will fail to start until the binary exists" >&2
  fi
  if [[ ! -x "$LLAMA_BIN" ]]; then
    echo "WARNING: llama-server binary not found at $LLAMA_BIN" >&2
    echo "         see INSTALL.md §6 for the symlink-install scheme" >&2
    echo "         continuing — llama-server.service will fail to start until it exists" >&2
  fi
fi

# ---------------- common paths

SYSTEMD_DIR=/etc/systemd/system
SUDOERS_DIR=/etc/sudoers.d
DEFAULT_DIR=/etc/default

UNITS=(
  mcp-csi-camera.service
  mcp-csi-camera-watchdog.service
  llama-server.service
  llama-server-watchdog.service
)
TIMERS=(
  mcp-csi-camera-watchdog.timer
  llama-server-watchdog.timer
)

# ---------------- uninstall path

if [[ "$UNINSTALL" -eq 1 ]]; then
  echo "==> uninstalling"
  for t in "${TIMERS[@]}";  do systemctl disable --now "$t" 2>/dev/null || true; done
  for u in "${UNITS[@]}";   do systemctl disable --now "$u" 2>/dev/null || true; done
  for f in "${UNITS[@]}" "${TIMERS[@]}"; do
    rm -fv "$SYSTEMD_DIR/$f" || true
  done
  rm -fv "$SUDOERS_DIR/mcp-watchdog" || true
  systemctl daemon-reload
  echo "==> done. /etc/default/{mcp-csi-camera,llama-server} kept (your config). Remove manually if unwanted."
  exit 0
fi

# ---------------- render helper

# render <input.in> <output>
#
# Substitutes @@REPO_ROOT@@, @@SERVICE_USER@@, @@LLAMA_BIN@@. Uses `|` as
# the sed delimiter because the values contain `/`. Writes to stdout if
# DRY_RUN, else to the target file with mode 0644 (or the per-target mode).
render() {
  local in="$1" out="$2" mode="${3:-0644}"
  local tmp
  tmp="$(mktemp)"
  sed \
    -e "s|@@REPO_ROOT@@|$REPO_ROOT|g" \
    -e "s|@@SERVICE_USER@@|$USER_NAME|g" \
    -e "s|@@LLAMA_BIN@@|$LLAMA_BIN|g" \
    "$in" > "$tmp"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "----- would write $out -----"
    cat "$tmp"
    echo "----- end $out -----"
    rm -f "$tmp"
  else
    install -m "$mode" "$tmp" "$out"
    rm -f "$tmp"
    echo "  wrote $out"
  fi
}

# write_default_if_missing <path> <content>
#
# Creates /etc/default/<file> with the given content, but only if the file
# does not already exist. Never clobbers user config.
write_default_if_missing() {
  local path="$1" content="$2"
  if [[ -f "$path" ]]; then
    echo "  keeping existing $path"
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "----- would write $path -----"
    echo "$content"
    echo "----- end $path -----"
  else
    install -m 0644 /dev/stdin "$path" <<<"$content"
    echo "  wrote $path"
  fi
}

# ---------------- render units

echo "==> rendering systemd units"
echo "    user:       $USER_NAME"
echo "    repo:       $REPO_ROOT"
echo "    llama-bin:  $LLAMA_BIN"

render "$SCRIPT_DIR/mcp-csi-camera.service.in"          "$SYSTEMD_DIR/mcp-csi-camera.service"
render "$SCRIPT_DIR/mcp-csi-camera-watchdog.service.in" "$SYSTEMD_DIR/mcp-csi-camera-watchdog.service"
render "$SCRIPT_DIR/llama-server.service.in"            "$SYSTEMD_DIR/llama-server.service"
render "$SCRIPT_DIR/llama-server-watchdog.service.in"   "$SYSTEMD_DIR/llama-server-watchdog.service"

# Timer files have no placeholders — copy as-is.
for t in "${TIMERS[@]}"; do
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "----- would copy $SCRIPT_DIR/$t -> $SYSTEMD_DIR/$t -----"
  else
    install -m 0644 "$SCRIPT_DIR/$t" "$SYSTEMD_DIR/$t"
    echo "  wrote $SYSTEMD_DIR/$t"
  fi
done

# ---------------- /etc/default/* stubs

echo "==> ensuring /etc/default/* config files exist (won't clobber if present)"

write_default_if_missing "$DEFAULT_DIR/mcp-csi-camera" \
"# /etc/default/mcp-csi-camera
#
# Edit, then: sudo systemctl restart mcp-csi-camera

# Where to bind. Default in unit: 0.0.0.0:8777
#MCP_CSI_LISTEN=0.0.0.0:8777

# Frame source. 'gstreamer' for real camera, 'mock' for plumbing tests.
#MCP_CSI_SOURCE=gstreamer

# Extra flags passed verbatim. Whitespace-split by systemd.
# Set --allowed-host to the IP/hostname your MCP clients dial in from.
#MCP_CSI_EXTRA_ARGS=--allowed-host 192.168.178.59

# Rust log filter (e.g. info, debug, mcp_csi_camera=debug).
#RUST_LOG=info
"

write_default_if_missing "$DEFAULT_DIR/llama-server" \
"# /etc/default/llama-server
#
# REQUIRED — the unit refuses to start without LLAMA_HF_MODEL. Edit this
# file, then: sudo systemctl restart llama-server

# Hugging Face model id, e.g.:
#   unsloth/Qwen3.5-0.8B-GGUF:Q8_0
#   ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF
LLAMA_HF_MODEL=unsloth/Qwen3.5-0.8B-GGUF:Q8_0

# Extra flags passed verbatim. Whitespace-split by systemd.
LLAMA_ARGS=--n-gpu-layers 99 --port 8776 --host 0.0.0.0 --reasoning-budget 128 --image-max-tokens 529
"

# ---------------- optional sudoers

if [[ "$WITH_SUDOERS" -eq 1 ]]; then
  echo "==> deploying optional sudoers (mode 0440 — required for sudoers)"
  render "$SCRIPT_DIR/sudoers.d-mcp-watchdog.in" "$SUDOERS_DIR/mcp-watchdog" 0440
  if [[ "$DRY_RUN" -eq 0 ]]; then
    # Validate the new sudoers rule before reload — a syntax error here
    # would break sudo system-wide. visudo -cf checks one file in isolation.
    if ! visudo -cf "$SUDOERS_DIR/mcp-watchdog" >/dev/null; then
      echo "ERROR: sudoers file is invalid — removing it" >&2
      rm -f "$SUDOERS_DIR/mcp-watchdog"
      exit 1
    fi
  fi
fi

# ---------------- enable + start

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> dry run, skipping daemon-reload / enable / start"
  exit 0
fi

echo "==> systemctl daemon-reload"
systemctl daemon-reload

echo "==> enabling units"
# Camera + its watchdog timer auto-start. llama-server is enabled too,
# but won't actually start until LLAMA_HF_MODEL is set in /etc/default.
systemctl enable mcp-csi-camera.service
systemctl enable mcp-csi-camera-watchdog.timer
systemctl enable llama-server.service
systemctl enable llama-server-watchdog.timer

echo "==> starting units (mcp-csi-camera + watchdog timers; llama-server only if env file is configured)"
systemctl start mcp-csi-camera.service || \
  echo "  (mcp-csi-camera failed to start — check 'journalctl -u mcp-csi-camera')"
systemctl start mcp-csi-camera-watchdog.timer

# Only start llama-server if user has configured a real HF model. The stub
# we wrote has a non-empty default so it'll actually try; if user just
# kept the stub model that's fine — they can `systemctl restart` later.
systemctl start llama-server.service || \
  echo "  (llama-server failed to start — edit /etc/default/llama-server and 'systemctl restart llama-server')"
systemctl start llama-server-watchdog.timer

echo
echo "==> done. Status check:"
echo "  systemctl status mcp-csi-camera mcp-csi-camera-watchdog.timer llama-server llama-server-watchdog.timer"
echo
echo "==> useful follow-ups:"
echo "  journalctl -u mcp-csi-camera -f                # live camera logs"
echo "  journalctl -u mcp-csi-camera-watchdog -e       # last camera watchdog runs"
echo "  journalctl -u llama-server -f                  # live llama-server logs"
echo "  journalctl -u llama-server-watchdog -e         # last llama watchdog runs"
echo "  curl -i http://127.0.0.1:8777/healthz          # manual camera probe"
echo "  curl -i http://127.0.0.1:8776/health           # manual llama probe"
echo "  systemctl list-timers '*-watchdog.timer'       # next probe times"
