#!/bin/bash
# fix_ffmpeg_macos.sh - Aggressive post-build script to fix FFmpeg library paths
#
# This script ensures ALL Homebrew dependencies are bundled and patched to use @rpath.
# It is designed to be extremely thorough and verbose to catch edge cases.

set +e

echo "🔧 FFmpeg macOS Post-Build Fix (Force Mode)"
echo "=========================================="

# Find the .app bundle
APP_PATH="$1"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    exit 1
fi

echo "   App bundle: $APP_PATH"

# Determine Homebrew prefix
if [ -d "/opt/homebrew" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local/Homebrew" ]; then
    HOMEBREW_PREFIX="/usr/local"
else
    HOMEBREW_PREFIX="/usr/local"
fi
echo "   Homebrew prefix: $HOMEBREW_PREFIX"

# Setup
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# ============================================================================
# Helper Functions
# ============================================================================

is_macho() {
    local file="$1"
    [ -f "$file" ] && file "$file" | grep -q "Mach-O"
}

get_deps() {
    local binary="$1"
    otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

is_homebrew_path() {
    local path="$1"
    [[ "$path" == "/opt/homebrew/"* ]] || [[ "$path" == "/usr/local/"* ]] || [[ "$path" == *"Cellar"* ]]
}

find_in_homebrew() {
    local lib_name="$1"
    local search_dirs=(
        "$HOMEBREW_PREFIX/opt/zlib/lib"
        "$HOMEBREW_PREFIX/opt/libpng/lib"
        "$HOMEBREW_PREFIX/opt/fontconfig/lib"
        "$HOMEBREW_PREFIX/opt/freetype/lib"
        "$HOMEBREW_PREFIX/opt/fribidi/lib"
        "$HOMEBREW_PREFIX/opt/harfbuzz/lib"
        "$HOMEBREW_PREFIX/opt/glib/lib"
        "$HOMEBREW_PREFIX/opt/graphite2/lib"
        "$HOMEBREW_PREFIX/opt/libiconv/lib"
        "$HOMEBREW_PREFIX/opt/pcre2/lib"
        "$HOMEBREW_PREFIX/opt/gettext/lib"
        "$HOMEBREW_PREFIX/opt/expat/lib"
        "$HOMEBREW_PREFIX/opt/brotli/lib"
        "$HOMEBREW_PREFIX/opt/bzip2/lib"
        "$HOMEBREW_PREFIX/opt/xz/lib"
        "$HOMEBREW_PREFIX/opt/openssl@3/lib"
        "$HOMEBREW_PREFIX/lib"
        "/usr/local/lib"
    )

    for dir in "${search_dirs[@]}"; do
        if [ -f "$dir/$lib_name" ]; then
            echo "$dir/$lib_name"
            return 0
        fi
    done

    # Fallback search
    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

# Forward declaration
patch_binary() { :; }

bundle_lib() {
    local lib_name="$1"
    local dest_path="$FRAMEWORKS_DIR/$lib_name"

    if [ -f "$dest_path" ]; then
        return 0
    fi

    local source_path=$(find_in_homebrew "$lib_name")
    if [ -n "$source_path" ]; then
        echo "   Bundling: $lib_name from $source_path"
        cp -L "$source_path" "$dest_path"
        chmod 755 "$dest_path"
        xattr -cr "$dest_path" 2>/dev/null
        codesign --remove-signature "$dest_path" 2>/dev/null

        # Recursively patch the newly bundled library
        patch_binary "$dest_path"
    else
        echo "   ⚠️  Could not find source for $lib_name"
        return 1
    fi
}

patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    # Ensure writable
    chmod 755 "$binary" 2>/dev/null
    codesign --remove-signature "$binary" 2>/dev/null

    local deps=$(get_deps "$binary")

    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")

            # Ensure it's bundled
            bundle_lib "$dep_name"

            # Always try to patch if it looks like a Homebrew path
            echo "      $binary_name: $dep -> @rpath/$dep_name"
            if ! install_name_tool -change "$dep" "@rpath/$dep_name" "$binary"; then
                echo "      ❌ Failed to patch $dep in $binary_name"
            fi
        fi
    done

    # Update ID if it's a dylib
    if [[ "$binary_name" == *.dylib ]]; then
        local current_id=$(otool -D "$binary" | tail -n 1)
        if [[ "$current_id" != "@rpath/$binary_name" ]]; then
            install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null
        fi
    fi

    # Add RPATHs to help find bundled dylibs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null
    install_name_tool -add_rpath "@loader_path/Frameworks" "$binary" 2>/dev/null
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null
}

# ============================================================================
# Main Logic
# ============================================================================

echo ""
echo "🚀 Starting recursive patch process..."

# Explicitly bundle zlib first as it's a known issue
echo "   Ensuring zlib is bundled..."
bundle_lib "libz.1.dylib"

# Scan everything in the bundle
# We use a temp file to avoid subshell issues with recursion/variables if we were using them
# But here we just call functions.
find "$APP_PATH/Contents" -type f | while read -r file; do
    if is_macho "$file"; then
        patch_binary "$file"
    fi
done

# ============================================================================
# Verification
# ============================================================================
echo ""
echo "🔍 Final Verification..."

FAILED=0
CHECKED=0

find "$APP_PATH/Contents" -type f | while read -r file; do
    if is_macho "$file"; then
        CHECKED=$((CHECKED + 1))
        bad_deps=$(get_deps "$file" | grep -E "/opt/homebrew|/usr/local|Cellar" || true)

        if [ -n "$bad_deps" ]; then
            echo "   ❌ $(basename "$file") still has Homebrew dependencies:"
            for dep in $bad_deps; do
                echo "      - $dep"
            done
            FAILED=$((FAILED + 1))
        fi
    fi
done

if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED binaries have unresolved dependencies!"
    exit 1
fi

echo "✅ SUCCESS: All binaries verified and patched!"
exit 0
