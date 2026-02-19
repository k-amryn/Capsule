#!/bin/bash
# fix_ffmpeg_macos.sh - Using dylibbundler for robust dependency management
#
# This script uses the specialized 'dylibbundler' tool to automatically
# find, copy, and patch Homebrew dependencies into the app bundle.

set -euo pipefail

echo "🔧 FFmpeg macOS Post-Build Fix (dylibbundler mode)"
echo "=================================================="

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    exit 1
fi

echo "App bundle: $APP_PATH"

# Ensure dylibbundler is installed
if ! command -v dylibbundler &> /dev/null; then
    echo "📦 Installing dylibbundler..."
    brew install dylibbundler
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Ensure everything is writable
chmod -R +w "$APP_PATH"

# Step 1: Use dylibbundler to bundle all dependencies
# We scan every Mach-O file in the bundle to ensure nothing is missed.
# Note: dylibbundler flags are -b (bundle) and -x (fix-file).
echo "🛠️  Bundling and patching dependencies..."
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        echo "   Processing: $(basename "$file")"
        # -of: overwrite files, -b: bundle deps, -x: fix file, -d: dest dir, -p: install path
        dylibbundler -of -b -x "$file" -d "$FRAMEWORKS_DIR" -p "@executable_path/../Frameworks" 2>/dev/null || true
    fi
done

# Step 2: Final verification
echo ""
echo "🔍 Final Verification..."
FAILED=0
TOTAL=0
while read -r bin; do
    if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
        TOTAL=$((TOTAL + 1))
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
