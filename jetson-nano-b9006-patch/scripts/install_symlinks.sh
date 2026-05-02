#!/usr/bin/env bash
# Symlink the llama.cpp b9006 binaries from this repo into a directory in
# PATH, with a configurable prefix so they don't clash with an older
# system-wide install (e.g. the b5050 binaries that kreier's install.sh
# drops into /usr/local/bin).
#
# Default behaviour: for every executable in <repo>/build/bin/llama-*,
# create a symlink at ~/.local/bin/r<name> (so `llama-cli` becomes
# `rllama-cli`).
#
# RPATH stays valid because the linker resolves it relative to the
# binary's real path, not the symlink.
#
# Usage:
#   ./jetson-nano-b9006-patch/scripts/install_symlinks.sh [options]
#
# Options:
#   -p, --prefix PFX     Prefix for symlink names (default: "r").
#   -t, --target  DIR    Where to put the symlinks (default: ~/.local/bin).
#   -s, --source  DIR    Where to look for binaries (default: <repo>/build/bin).
#   -P, --pattern GLOB   Glob for binary names (default: "llama-*").
#   -n, --dry-run        Print what would be done, do not touch the filesystem.
#   -h, --help           Show this help and exit.
#
# Examples:
#   ./jetson-nano-b9006-patch/scripts/install_symlinks.sh
#   ./jetson-nano-b9006-patch/scripts/install_symlinks.sh -p new_
#   ./jetson-nano-b9006-patch/scripts/install_symlinks.sh -t /usr/local/bin -p ""
#   ./jetson-nano-b9006-patch/scripts/install_symlinks.sh --dry-run
#
# Re-run any time. Symlinks are recreated with `ln -sfn` (idempotent).

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PREFIX="r"
TARGET_DIR="$HOME/.local/bin"
SOURCE_DIR="$REPO_ROOT/build/bin"
PATTERN="llama-*"
DRY_RUN=0

show_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)   [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; PREFIX="$2"; shift 2;;
        -t|--target)   [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; TARGET_DIR="$2"; shift 2;;
        -s|--source)   [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; SOURCE_DIR="$2"; shift 2;;
        -P|--pattern)  [[ $# -lt 2 ]] && { echo "error: $1 requires an argument" >&2; exit 2; }; PATTERN="$2"; shift 2;;
        -n|--dry-run)  DRY_RUN=1; shift;;
        -h|--help)     show_help; exit 0;;
        *)             echo "error: unknown argument: $1" >&2; echo "run with --help for usage" >&2; exit 2;;
    esac
done

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "error: source directory does not exist: $SOURCE_DIR" >&2
    echo "       (did you build the project? expected build/bin under $REPO_ROOT)" >&2
    exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$TARGET_DIR"
fi

case ":$PATH:" in
    *":$TARGET_DIR:"*) ;;
    *)
        echo "warning: $TARGET_DIR is not in PATH"
        echo "         add this to your ~/.bashrc:"
        echo "           export PATH=\"$TARGET_DIR:\$PATH\""
        echo
        ;;
esac

echo "==> Source:  $SOURCE_DIR"
echo "==> Target:  $TARGET_DIR"
echo "==> Prefix:  ${PREFIX:-(none)}"
echo "==> Pattern: $PATTERN"
[[ "$DRY_RUN" -eq 1 ]] && echo "==> DRY RUN — no changes will be made"
echo

shopt -s nullglob
created=0
skipped=0

for src in "$SOURCE_DIR"/$PATTERN; do
    # Skip directories, non-executables, and shared libraries (e.g. libllama.so).
    if [[ -d "$src" ]] || [[ ! -x "$src" ]] || [[ "$src" == *.so ]] || [[ "$src" == *.so.* ]]; then
        continue
    fi
    name="$(basename "$src")"
    dest="$TARGET_DIR/${PREFIX}${name}"
    printf '  %s -> %s\n' "$dest" "$src"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        ln -sfn "$src" "$dest"
        created=$((created + 1))
    else
        skipped=$((skipped + 1))
    fi
done

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> Would create $skipped symlink(s)"
else
    echo "==> Created/refreshed $created symlink(s)"
    echo "==> Try: ${PREFIX}llama-cli --version"
fi
