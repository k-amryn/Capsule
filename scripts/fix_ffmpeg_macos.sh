#!/bin/bash
# fix_ffmpeg_macos.sh - Super Nuclear Option
#
# This script is designed to be the ultimate solution for bundling Homebrew
# dependencies in a macOS app bundle. It uses an aggressive, recursive
# approach to ensure every single dependency is caught and patched.

set -uo pipefail

echo "☢️  FFmpeg macOS Post-Build Fix (SUPER NUCLEAR OPTION)"
echo "====================================================="

# Find the .app bundle
APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    exit 1
fi

echo "App bundle: $APP_PATH"

# Detect Homebrew prefix
if [ -d "/opt/homebrew" ]; then
    BREW_PREFIX="/opt/homebrew"
else
    BREW_PREFIX="/usr/local"
fi
echo "Homebrew prefix: $BREW_PREFIX"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Ensure everything is writable
chmod -R +w "$APP_PATH"

# ============================================================================
# Helper Functions
# ============================================================================

is_macho() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q "Mach-O"
}

get_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

is_homebrew_path() {
    [[ "$1" == "/opt/homebrew/"* ]] || [[ "$1" == "/usr/local/opt/"* ]] || [[ "$1" == "/usr/local/Cellar/"* ]]
}

# ============================================================================
# The Core Logic: Recursive Bundling and Patching
# ============================================================================

bundle_and_patch() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    if ! is_macho "$binary"; then
        return 0
    fi

    echo "   Scanning: $binary_name"

    # Remove signature to allow patching
    codesign --remove-signature "$binary" 2>/dev/null || true

    local deps=$(get_deps "$binary")
    local changed=0

    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")
            local dest="$FRAMEWORKS_DIR/$dep_name"

            # 1. Bundle if missing
            if [ ! -f "$dest" ]; then
                echo "      📦 Bundling dependency: $dep_name"
                # Find the source
                local src="$dep"
                if [ ! -f "$src" ]; then
                    # Try to find it via brew prefix if the path in the binary is broken
                    local formula=$(echo "$dep" | cut -d'/' -f4)
                    local prefix=$(brew --prefix "$formula" 2>/dev/null || echo "")
                    if [ -n "$prefix" ] && [ -f "$prefix/lib/$dep_name" ]; then
                        src="$prefix/lib/$dep_name"
                    else
                        # Last resort: find anywhere in Homebrew
                        src=$(find "$BREW_PREFIX" -name "$dep_name" -type f 2>/dev/null | head -n 1)
                    fi
                fi

                if [ -n "$src" ] && [ -f "$src" ]; then
                    cp -L "$src" "$dest"
                    chmod 755 "$dest"
                    # Recursively process the newly bundled library
                    bundle_and_patch "$dest"
                else
                    echo "      ⚠️  WARNING: Could not find source for $dep"
                    continue
                fi
            fi

            # 2. Patch the binary to use @rpath
            # We use -arch flags for FAT binaries to be absolutely sure
            local archs=$(lipo -archs "$binary" 2>/dev/null || echo "")
            if [ -n "$archs" ]; then
                for arch in $archs; do
                    install_name_tool -arch "$arch" -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
                done
            fi
            # Also run without -arch as a catch-all
            install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
            changed=1
        fi
    done

    # Update dylib ID if it's a library
    if [[ "$binary_name" == *.dylib ]] || [[ "$binary" == *".framework/"* ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null || true
    fi

    # Add standard RPATHs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

# ============================================================================
# Execution
# ============================================================================

echo ""
echo "🚀 Phase 1: Initial scan and recursive bundling..."
# We use a temporary file to store the list of binaries to avoid subshell issues
BINARIES_TO_PATCH=$(mktemp)
find "$APP_PATH/Contents" -type f > "$BINARIES_TO_PATCH"

while read -r file; do
    if is_macho "$file"; then
        bundle_and_patch "$file"
    fi
done < "$BINARIES_TO_PATCH"

echo ""
echo "🚀 Phase 2: Final sweep of all bundled libraries..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] && bundle_and_patch "$dylib"
done

# ============================================================================
# Verification
# ============================================================================

echo ""
echo "🔍 Phase 3: Final Verification..."

FAILED=0
TOTAL=0

while read -r file; do
    if is_macho "$file"; then
        TOTAL=$((TOTAL + 1))
        name=$(basename "$file")
        bad_deps=$(otool -L "$file" 2>/dev/null | tail -n +2 | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)

        if [ -n "$bad_deps" ]; then
            echo "   ❌ $name still has unresolved Homebrew dependencies:"
            echo "$bad_deps" | awk '{print "      - " $1}'
            FAILED=$((FAILED + 1))
        fi
    fi
done < "$BINARIES_TO_PATCH"

rm -f "$BINARIES_TO_PATCH"

echo ""
echo "=============================================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified and patched!"
exit 0
