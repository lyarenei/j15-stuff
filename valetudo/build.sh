#!/usr/bin/env bash
# Builds the patched Valetudo for the robot (aarch64) into build/valetudo-aarch64.
#
#   valetudo/build.sh
#
# Clones upstream Valetudo at the tag in valetudo/BASE, applies valetudo/patches/*.patch
# with git am, then builds the frontend and the aarch64 backend binary.
#
# Environment:
#   VALETUDO_SRC=/path   build this existing checkout as it is (no clone, no patches);
#                        npm ci is skipped if node_modules exists
#   VALETUDO_CACHE=dir   where the clone lives (default: build/valetudo-src)

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
UPSTREAM=https://github.com/Hypfer/Valetudo
BASE=$(tr -d '[:space:]' < "$HERE/BASE")
CACHE=${VALETUDO_CACHE:-$ROOT/build/valetudo-src}
OUT=$ROOT/build/valetudo-aarch64
BRANCH=j15-patched

die() { echo "error: $*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

for tool in git node npm; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
[ -n "$BASE" ] || die "valetudo/BASE is empty"

if [ -n "${VALETUDO_SRC:-}" ]; then
    SRC=$VALETUDO_SRC
    [ -f "$SRC/package.json" ] || die "$SRC is not a Valetudo checkout"
    echo "Using $SRC as it is (no patches applied)"
else
    SRC=$CACHE
    if [ ! -d "$SRC/.git" ]; then
        echo "Cloning $UPSTREAM into $SRC..."
        mkdir -p "$(dirname "$SRC")"
        git clone --quiet --filter=blob:none "$UPSTREAM" "$SRC"
    else
        echo "Updating $SRC..."
        git -C "$SRC" fetch --quiet --tags --force origin
    fi
    git -C "$SRC" rev-parse --verify --quiet "refs/tags/$BASE^{commit}" >/dev/null \
        || die "tag $BASE not found upstream"

    git -C "$SRC" am --abort >/dev/null 2>&1 || true
    git -C "$SRC" checkout --quiet --force -B "$BRANCH" "refs/tags/$BASE"
    git -C "$SRC" clean --quiet -fd -e node_modules -e build_dependencies

    set -- "$HERE"/patches/*.patch
    if [ -e "$1" ]; then
        echo "Applying $# patch(es) on $BASE..."
        if ! git -C "$SRC" -c user.name=j15 -c user.email=j15@localhost am --3way --quiet "$@"; then
            echo >&2
            echo "error: a patch failed to apply (see above)." >&2
            echo "Fix it in $SRC (resolve, git add, git am --continue)," >&2
            echo "then run valetudo/export-patches.sh $SRC" >&2
            exit 1
        fi
    else
        echo "No patches in valetudo/patches, building stock $BASE"
    fi
fi

LOCK_SHA=$(sha256 "$SRC/package-lock.json")
if [ -d "$SRC/node_modules" ] && { [ -n "${VALETUDO_SRC:-}" ] || [ "$(cat "$SRC/node_modules/.j15-lock" 2>/dev/null)" = "$LOCK_SHA" ]; }; then
    echo "node_modules present, skipping npm ci"
else
    echo "Installing dependencies..."
    (cd "$SRC" && npm ci)
    echo "$LOCK_SHA" > "$SRC/node_modules/.j15-lock"
fi

echo "Building frontend..."
(cd "$SRC" && npm run build --workspace=frontend)
echo "Generating OpenAPI schema..."
(cd "$SRC" && npm run build_openapi_schema)
echo "Building backend (aarch64)..."
(cd "$SRC" && npm run build_aarch64 --workspace=backend)

[ -f "$SRC/build/aarch64/valetudo" ] || die "build produced no $SRC/build/aarch64/valetudo"
mkdir -p "$ROOT/build"
cp "$SRC/build/aarch64/valetudo" "$OUT"
chmod 755 "$OUT"

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "sha256 $(sha256 "$OUT")"
