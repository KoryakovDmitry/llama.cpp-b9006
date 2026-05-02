#!/usr/bin/env bash
# Run `cmake --build build --config Release` and capture stdout+stderr to a
# log file while still streaming to the terminal. The exit code from cmake
# is preserved (not the always-zero exit code from tee).
#
# Usage:
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh [options] [logfile] [-- cmake-build-args...]
#
# Options:
#   -o, --output PATH    Full path of the log file (overrides --dir/--file).
#   -d, --dir    DIR     Directory to write the log into.
#   -f, --file   NAME    Log filename (used inside --dir, or alongside default dir).
#   -h, --help           Show this help and exit.
#
# Anything after `--` is forwarded verbatim to `cmake --build`. Use this to
# pass things like parallelism, e.g.:
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -- -j2
#
# A positional argument is accepted as a backwards-compatible alias for --output.
#
# Defaults:
#   --dir  jetson-nano-ability-instruction-based-on-b5050/compile_logs
#   --file build_log.txt
#
# Examples:
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -f failed_logs_round_4.txt
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -d logs -f round5.txt
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -o some/where/full.log
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -- -j2
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh -f round_libressl.txt -- -j2
#   ./jetson-nano-b9006-patch/scripts/build_with_log.sh jetson-nano-ability-instruction-based-on-b5050/failed_logs_round_4.txt
#
# Run from the repository root.

set -u

DEFAULT_DIR="jetson-nano-ability-instruction-based-on-b5050/compile_logs"
DEFAULT_FILE="build_log.txt"

show_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

OUTPUT=""
DIR=""
FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }
            OUTPUT="$2"; shift 2;;
        -d|--dir)
            [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }
            DIR="$2"; shift 2;;
        -f|--file)
            [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }
            FILE="$2"; shift 2;;
        -h|--help)
            show_help; exit 0;;
        --)
            shift; break;;
        -*)
            echo "error: unknown option: $1" >&2
            echo "run with --help for usage" >&2
            exit 2;;
        *)
            if [[ -z "$OUTPUT" ]]; then
                OUTPUT="$1"
            else
                echo "error: unexpected positional argument: $1" >&2
                exit 2
            fi
            shift;;
    esac
done

if [[ -n "$OUTPUT" ]]; then
    LOG="$OUTPUT"
else
    LOG="${DIR:-$DEFAULT_DIR}/${FILE:-$DEFAULT_FILE}"
fi

mkdir -p "$(dirname "$LOG")"

echo "==> Logging to: $LOG"
echo "==> Started:    $(date -Iseconds)"
if [[ $# -gt 0 ]]; then
    echo "==> Extra args: $*"
fi
echo

# Use a subshell with pipefail so cmake's exit code propagates through `tee`.
(
    set -o pipefail
    cmake --build build --config Release "$@" 2>&1 | tee "$LOG"
)
EXIT=$?

echo
echo "==> Finished:   $(date -Iseconds)"
echo "==> Exit code:  $EXIT"

exit "$EXIT"
