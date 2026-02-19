#!/bin/bash
# fix_ffmpeg_macos.sh - Robust dependency bundling using dylibbundler
#
# This script uses dylibbundler to recursively find and bundle Homebrew dependencies.
# It performs multiple passes to ensure that dependencies of dependencies (e.g., libsrt -> openssl)
# are correctly captured and patched.

set -euo pipefail

echo "🔧 FFmpeg macOS Post-Build Fix (dylibbundler recursive mode)"
echo "=========================================================="

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    exit 1
fi

echo "App bundle: $APP_PATH"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Ensure everything is writable
chmod -R +w "$APP_PATH"

# Detect Homebrew prefix
BREW_PREFIX=$(brew --prefix)

# Function to run dylibbundler on a specific file
# We include common Homebrew paths in the search path (-s) to ensure deep dependencies are found
fix_file() {
    local file="$1"
    echo "   Processing: $(basename "$file")"

    # -of: overwrite files in destination
    # -b: bundle dependencies
    # -x: fix the file's load commands
    # -d: destination directory for bundled libraries
    # -p: prefix for the internal path (standard for macOS apps)
    # -s: additional search paths for Homebrew formulas that are often keg-only
    dylibbundler -of -b -x "$file" \
        -d "$FRAMEWORKS_DIR" \
        -p "@executable_path/../Frameworks" \
        -s "$BREW_PREFIX/lib" \
        -s "$BREW_PREFIX/opt/openssl@3/lib" \
        -s "$BREW_PREFIX/opt/zlib/lib" \
        -s "$BREW_PREFIX/opt/icu4c/lib" \
        -s "$BREW_PREFIX/opt/libiconv/lib" \
        2>/dev/null || true
}

# Phase 1: Process all binaries in the main app bundle
echo "🚀 Phase 1: Initial bundling pass for all binaries..."
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        fix_file "$file"
    fi
done

# Phase 2: Recursive pass specifically for the bundled libraries
# This ensures that if a bundled library (like libsrt) has its own Homebrew
# dependencies (like openssl), they are also bundled and patched.
echo "🚀 Phase 2: Recursive bundling pass for bundled libraries..."
find "$FRAMEWORKS_DIR" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        fix_file "$file"
    fi
done

# Phase 3: Final Verification
echo ""
echo "🔍 Final Verification..."
FAILED=0
TOTAL=0
while read -r bin; do
    if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
        TOTAL=$((TOTAL + 1))
        # Check for any remaining absolute paths to Homebrew or /usr/local
        BAD_DEPS=$(otool -L "$bin" 2>/dev/null | grep -E "/opt/homebrew|/usr/local" || true)
        if [ -n "$BAD_DEPS" ]; then
            echo "   ❌ FAILED: $(basename "$bin") still has Homebrew paths"
            echo "$BAD_DEPS" | sed 's/^/      /'
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$APP_PATH/Contents" -type f)

if [ "$FAILED" -gt 0 ]; then
    echo "❌ Error: $FAILED of $TOTAL binaries failed verification."
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified and patched!"
exit 0
