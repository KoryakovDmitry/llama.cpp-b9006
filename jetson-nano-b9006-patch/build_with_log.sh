#!/usr/bin/env bash
# Run `cmake --build build --config Release` and capture stdout+stderr to a
# log file while still streaming to the terminal. The exit code from cmake
# is preserved (not the always-zero exit code from tee).
#
# Usage:
#   ./jetson-nano-b9006-patch/build_with_log.sh
#   ./jetson-nano-b9006-patch/build_with_log.sh path/to/custom.log
#
# Default log path: jetson-nano-ability-instruction-based-on-b5050/build_log.txt
#
# Run from the repository root.

set -u

LOG="${1:-jetson-nano-ability-instruction-based-on-b5050/build_log.txt}"
mkdir -p "$(dirname "$LOG")"

echo "==> Logging to: $LOG"
echo "==> Started:    $(date -Iseconds)"
echo

# Use a subshell with pipefail so cmake's exit code propagates through `tee`.
(
    set -o pipefail
    cmake --build build --config Release 2>&1 | tee "$LOG"
)
EXIT=$?

echo
echo "==> Finished:   $(date -Iseconds)"
echo "==> Exit code:  $EXIT"

exit "$EXIT"
