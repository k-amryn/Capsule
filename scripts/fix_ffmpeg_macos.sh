#!/bin/bash
# fix_ffmpeg_macos.sh - Robust macOS Dependency Bundler using dylibbundler
#
# This script uses the specialized 'dylibbundler' tool to automatically
# find, copy, and patch Homebrew dependencies into the app bundle.
#
# It follows a first-principles approach:
# 1. Identify all Mach-O binaries in the bundle.
# 2. Use dylibbundler to recursively find and bundle their dependencies.
# 3. Relink all binaries to use relative paths (@executable_path/../Frameworks).
# 4. Verify that no absolute Homebrew paths remain.

set -euo pipefail

echo "🔧 FFmpeg macOS Post-Build Fix (dylibbundler mode)"
echo "=================================================="

# 1. Find the .app bundle
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

# 2. Ensure all files are writable for patching
chmod -R +w "$APP_PATH"

# 3. Process all Mach-O files in the bundle
echo "🛠️  Bundling and patching dependencies..."
# We find every file and check if it's a Mach-O binary (executable, dylib, or framework)
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        echo "   Processing: $(basename "$file")"

        # dylibbundler flags:
        # -of: Overwrite the file with the patched version
        # -b:  Bundle dependencies (copy them to the destination)
        # -x:  Fix the provided file
        # -d:  Destination directory for bundled libraries
        # -p:  Prefix to use for the new load commands
        #
        # We use @executable_path/../Frameworks as the prefix because it is the
        # standard location for bundled libraries in macOS apps.
        dylibbundler -of -b -x "$file" -d "$FRAMEWORKS_DIR" -p "@executable_path/../Frameworks" 2>/dev/null || true
    fi
done

# 4. Final Zero-Tolerance Verification
echo ""
echo "🔍 Final Verification..."
FAILED=0
# Scan every file again to ensure no Homebrew or /usr/local paths remain
while read -r bin; do
    if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
        # Check for any remaining absolute paths to Homebrew or /usr/local
        BAD_DEPS=$(otool -L "$bin" 2>/dev/null | grep -E "/opt/homebrew|/usr/local" || true)
        if [ -n "$BAD_DEPS" ]; then
            echo "   ❌ FAILED: $(basename "$bin") still has absolute paths:"
            echo "$BAD_DEPS" | sed 's/^/      /'
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$APP_PATH/Contents" -type f)

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "❌ Error: $FAILED binaries failed verification. The bundle is not portable."
    exit 1
fi

echo ""
echo "✅ SUCCESS: All binaries verified and patched!"
echo "🎉 App bundle is now self-contained and ready for distribution."
exit 0
