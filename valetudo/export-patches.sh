#!/usr/bin/env bash
# Regenerates valetudo/patches/ from the commits on top of the base tag.
#
#   valetudo/export-patches.sh [valetudo-checkout]   (default: build/valetudo-src)
#
# The checkout's HEAD must be a branch of commits on top of the tag in valetudo/BASE.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BASE=$(tr -d '[:space:]' < "$HERE/BASE")
SRC=${1:-$ROOT/build/valetudo-src}

[ -d "$SRC/.git" ] || { echo "error: $SRC is not a git checkout" >&2; exit 1; }
git -C "$SRC" rev-parse --verify --quiet "refs/tags/$BASE^{commit}" >/dev/null \
    || { echo "error: tag $BASE not found in $SRC" >&2; exit 1; }
git -C "$SRC" merge-base --is-ancestor "refs/tags/$BASE" HEAD \
    || { echo "error: HEAD is not based on $BASE" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] \
    || { echo "error: uncommitted changes in $SRC; commit them first" >&2; exit 1; }

if [ -z "$(git -C "$SRC" rev-list "refs/tags/$BASE..HEAD")" ]; then
    echo "error: no commits on top of $BASE" >&2
    exit 1
fi

find "$HERE/patches" -name '*.patch' -delete
git -C "$SRC" format-patch --quiet --no-signature --zero-commit --no-stat \
    -o "$HERE/patches" "refs/tags/$BASE..HEAD"

echo "Wrote $(find "$HERE/patches" -name '*.patch' | wc -l | tr -d ' ') patch(es) to valetudo/patches/:"
ls "$HERE/patches"
