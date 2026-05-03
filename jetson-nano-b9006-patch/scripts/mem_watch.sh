#!/usr/bin/env bash
# Periodically snapshot memory + swap state and tee it into a log file.
# Run this in a separate terminal/TTY/SSH session while llama-cli is doing
# its thing in another. The log captures whether the system entered swap
# thrashing right when CUDA reported "the launch timed out" — which is
# what we need to distinguish "memory pressure" from a real GPU watchdog.
#
# Usage:
#   ./jetson-nano-b9006-patch/scripts/mem_watch.sh [options]
#
# Options:
#   -i, --interval SEC   Sampling interval in seconds (default: 0.5).
#   -o, --output PATH    Full path of the log file (overrides --dir/--file).
#   -d, --dir    DIR     Directory to write the log into.
#   -f, --file   NAME    Log filename (used inside --dir).
#   -q, --quiet          Don't echo to stdout, only write to the log.
#   -h, --help           Show this help and exit.
#
# Defaults:
#   --dir       jetson-nano-ability-instruction-based-on-b5050/compile_logs
#   --file      mem_watch_<ISO timestamp>.txt
#   --interval  0.5
#
# Examples:
#   ./jetson-nano-b9006-patch/scripts/mem_watch.sh
#   ./jetson-nano-b9006-patch/scripts/mem_watch.sh -i 1
#   ./jetson-nano-b9006-patch/scripts/mem_watch.sh -o ~/memlog.txt
#   ./jetson-nano-b9006-patch/scripts/mem_watch.sh -f run_qwen_vision.txt
#
# Stop with Ctrl+C. The script catches it and prints the log path.

set -u

DEFAULT_DIR="jetson-nano-ability-instruction-based-on-b5050/compile_logs"

INTERVAL="0.5"
OUTPUT=""
DIR=""
FILE=""
QUIET=0

show_help() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interval) [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; INTERVAL="$2"; shift 2;;
        -o|--output)   [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; OUTPUT="$2"; shift 2;;
        -d|--dir)      [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; DIR="$2"; shift 2;;
        -f|--file)     [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; FILE="$2"; shift 2;;
        -q|--quiet)    QUIET=1; shift;;
        -h|--help)     show_help; exit 0;;
        *)             echo "error: unknown argument: $1" >&2; echo "run with --help for usage" >&2; exit 2;;
    esac
done

if [[ -z "$OUTPUT" ]]; then
    : "${DIR:=$DEFAULT_DIR}"
    : "${FILE:=mem_watch_$(date +%Y%m%dT%H%M%S).txt}"
    LOG="$DIR/$FILE"
else
    LOG="$OUTPUT"
fi

mkdir -p "$(dirname "$LOG")"

echo "==> Logging memory snapshots to: $LOG"
echo "==> Interval: ${INTERVAL}s   (Ctrl+C to stop)"
echo

cleanup() {
    echo
    echo "==> Stopped at $(date -Iseconds)"
    echo "==> Log file: $LOG"
    exit 0
}
trap cleanup INT TERM

emit() {
    {
        printf '=== %s ===\n' "$(date -Iseconds)"
        free -h | head -3
        echo '---'
        cat /proc/swaps
        echo
    }
}

if [[ "$QUIET" -eq 1 ]]; then
    while true; do
        emit >> "$LOG"
        sleep "$INTERVAL"
    done
else
    while true; do
        emit | tee -a "$LOG"
        sleep "$INTERVAL"
    done
fi