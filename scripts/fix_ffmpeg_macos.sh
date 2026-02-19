#!/bin/bash
# fix_ffmpeg_macos.sh
#
# Strategy:
#   1. dylibbundler handles the heavy lifting - it recursively finds, copies, and
#      relinks Homebrew dependencies. It handles the malformed __LINKEDIT segments
#      in the FFmpeg frameworks that Apple's install_name_tool cannot.
#
#   2. A manual sweep catches anything dylibbundler skipped. This happens when a
#      dependency is already present in Frameworks (e.g. libssl.3.dylib was bundled
#      in pass 1, so dylibbundler skips copying it in pass 2 and also skips patching
#      the binary that depends on it - e.g. libsrt.1.5.dylib).
#
#   3. Zero-tolerance verification confirms no absolute Homebrew paths remain.

set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the .app bundle
# ---------------------------------------------------------------------------
APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌  Could not find .app bundle"
    exit 1
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
BREW_PREFIX=$(brew --prefix)

echo "🔧  fix_ffmpeg_macos.sh"
echo "    App:        $APP_PATH"
echo "    Brew:       $BREW_PREFIX"
echo "    Frameworks: $FRAMEWORKS_DIR"
echo ""

mkdir -p "$FRAMEWORKS_DIR"
chmod -R +w "$APP_PATH"

# ---------------------------------------------------------------------------
# Helper: run dylibbundler on a single Mach-O file
# We supply explicit -s paths for keg-only formulae that aren't in
# $BREW_PREFIX/lib by default, so dylibbundler can locate their sources.
# ---------------------------------------------------------------------------
run_dylibbundler() {
    local file="$1"
    dylibbundler \
        -of \
        -b \
        -x  "$file" \
        -d  "$FRAMEWORKS_DIR" \
        -p  "@executable_path/../Frameworks" \
        -s  "$BREW_PREFIX/lib" \
        -s  "$BREW_PREFIX/opt/openssl@3/lib" \
        -s  "$BREW_PREFIX/opt/zlib/lib" \
        -s  "$BREW_PREFIX/opt/libiconv/lib" \
        -s  "$BREW_PREFIX/opt/gettext/lib" \
        -s  "$FRAMEWORKS_DIR" \
        2>/dev/null || true
}

# Helper: is this file a Mach-O binary?
is_macho() {
    [ -f "$1" ] && file -b "$1" | grep -q "Mach-O"
}

# ---------------------------------------------------------------------------
# PASS 1 – dylibbundler over every Mach-O in the bundle
# This handles the FFmpeg frameworks whose __LINKEDIT segments are malformed
# and cannot be patched by Apple's install_name_tool.
# ---------------------------------------------------------------------------
echo "📦  Pass 1: dylibbundler on all bundle binaries..."
while IFS= read -r -d '' f; do
    if is_macho "$f"; then
        echo "    $(basename "$f")"
        run_dylibbundler "$f"
    fi
done < <(find "$APP_PATH/Contents" -type f -print0)

# ---------------------------------------------------------------------------
# PASS 2 – dylibbundler over every Mach-O in Frameworks
# Newly-bundled libraries may have their own Homebrew deps; this catches them.
# ---------------------------------------------------------------------------
echo ""
echo "📦  Pass 2: dylibbundler on bundled dylibs..."
while IFS= read -r -d '' f; do
    if is_macho "$f"; then
        echo "    $(basename "$f")"
        run_dylibbundler "$f"
    fi
done < <(find "$FRAMEWORKS_DIR" -type f -print0)

# ---------------------------------------------------------------------------
# PASS 3 – Manual sweep with install_name_tool
# dylibbundler skips patching a binary when its dependency is already present
# in $FRAMEWORKS_DIR (it copies nothing, so it patches nothing).  We catch
# those stragglers here.  Thin binaries (e.g. libsrt) are handled fine by
# the standard install_name_tool.
# ---------------------------------------------------------------------------
echo ""
echo "🔧  Pass 3: manual sweep for any remaining absolute paths..."
while IFS= read -r -d '' file; do
    if ! is_macho "$file"; then
        continue
    fi

    # Collect all remaining Homebrew-absolute load paths in this binary
    remaining=$(otool -L "$file" 2>/dev/null \
        | tail -n +2 \
        | awk '{print $1}' \
        | grep -E "^/opt/homebrew|^/usr/local" || true)

    for dep in $remaining; do
        lib_name=$(basename "$dep")
        dest="$FRAMEWORKS_DIR/$lib_name"

        # If the library isn't bundled yet, try to find and copy it
        if [ ! -f "$dest" ]; then
            src=$(find "$BREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
            if [ -n "$src" ]; then
                echo "    bundling late dep: $lib_name"
                cp -L "$src" "$dest"
                chmod 755 "$dest"
            else
                echo "    ⚠️  cannot find source for $lib_name – skipping"
                continue
            fi
        fi

        echo "    relinking $(basename "$file") → $lib_name"
        install_name_tool \
            -change "$dep" \
            "@executable_path/../Frameworks/$lib_name" \
            "$file" 2>/dev/null || true
    done
done < <(find "$APP_PATH/Contents" -type f -print0)

# ---------------------------------------------------------------------------
# VERIFY – zero tolerance for remaining absolute Homebrew paths
# ---------------------------------------------------------------------------
echo ""
echo "🔍  Verification..."
FAILED=0
TOTAL=0

while IFS= read -r -d '' bin; do
    if ! is_macho "$bin"; then
        continue
    fi
    TOTAL=$((TOTAL + 1))

    bad=$(otool -L "$bin" 2>/dev/null \
        | grep -E "/opt/homebrew|/usr/local" || true)

    if [ -n "$bad" ]; then
        echo "    ❌  $(basename "$bin") still has absolute paths:"
        echo "$bad" | sed 's/^/        /'
        FAILED=$((FAILED + 1))
    fi
done < <(find "$APP_PATH/Contents" -type f -print0)

echo ""
echo "======================================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌  FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅  SUCCESS: all $TOTAL binaries are clean"
exit 0
