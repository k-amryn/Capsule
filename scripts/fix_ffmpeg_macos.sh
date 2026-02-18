#!/bin/bash
# fix_ffmpeg_macos.sh - Post-build script to fix FFmpeg library paths in the final .app bundle
#
# This script patches the final .app bundle AFTER Flutter builds it.
# It ensures all Homebrew dependencies are bundled and patched to use @rpath.
#
# Usage:
#   ./scripts/fix_ffmpeg_macos.sh [path/to/App.app]

set +e

echo "🔧 FFmpeg macOS Post-Build Fix"
echo "==============================="
echo ""

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
TEMP_DIR=$(mktemp -d)
mkdir -p "$FRAMEWORKS_DIR"

# Temp file for tracking dependencies
HOMEBREW_DEPS_FILE=$(mktemp)
trap "rm -rf $TEMP_DIR $HOMEBREW_DEPS_FILE" EXIT

# ============================================================================
# Helper Functions
# ============================================================================

should_skip_lib() {
    local lib_name="$1"
    case "$lib_name" in
        libsrt*) return 0 ;;
        # We bundle these now to be safe, but keep the function for future exclusions
    esac
    return 1
}

is_system_path() {
    local path="$1"
    case "$path" in
        /System/Library/*) return 0 ;;
        /usr/lib/libSystem*) return 0 ;;
        /usr/lib/libc++*) return 0 ;;
        /usr/lib/libobjc*) return 0 ;;
        /usr/lib/libz.*) return 0 ;;
        /usr/lib/libbz2.*) return 0 ;;
        /usr/lib/liblzma.*) return 0 ;;
        /usr/lib/libiconv.*) return 0 ;;
        @rpath/*) return 0 ;;
        @executable_path/*) return 0 ;;
        @loader_path/*) return 0 ;;
    esac
    return 1
}

find_in_homebrew() {
    local lib_name="$1"
    local search_dirs="
        $HOMEBREW_PREFIX/opt/libpng/lib
        $HOMEBREW_PREFIX/opt/fontconfig/lib
        $HOMEBREW_PREFIX/opt/freetype/lib
        $HOMEBREW_PREFIX/opt/fribidi/lib
        $HOMEBREW_PREFIX/opt/harfbuzz/lib
        $HOMEBREW_PREFIX/opt/glib/lib
        $HOMEBREW_PREFIX/opt/graphite2/lib
        $HOMEBREW_PREFIX/opt/libiconv/lib
        $HOMEBREW_PREFIX/opt/pcre2/lib
        $HOMEBREW_PREFIX/opt/gettext/lib
        $HOMEBREW_PREFIX/opt/zlib/lib
        $HOMEBREW_PREFIX/opt/expat/lib
        $HOMEBREW_PREFIX/opt/brotli/lib
        $HOMEBREW_PREFIX/opt/bzip2/lib
        $HOMEBREW_PREFIX/opt/xz/lib
        $HOMEBREW_PREFIX/opt/openssl@3/lib
        $HOMEBREW_PREFIX/lib
    "

    for dir in $search_dirs; do
        if [ -f "$dir/$lib_name" ]; then
            echo "$dir/$lib_name"
            return 0
        fi
    done

    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

get_deps() {
    local binary="$1"
    otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

is_fat_binary() {
    local binary="$1"
    lipo -info "$binary" 2>/dev/null | grep -q "are:"
}

patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    [ ! -f "$binary" ] && return 0

    # Check if it's actually a Mach-O binary
    if ! file "$binary" | grep -q "Mach-O"; then
        return 0
    fi

    echo "   Patching: $binary_name"

    chmod 755 "$binary" 2>/dev/null
    xattr -cr "$binary" 2>/dev/null
    codesign --remove-signature "$binary" 2>/dev/null

    local deps=$(get_deps "$binary")
    for dep in $deps; do
        if is_system_path "$dep"; then
            continue
        fi

        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local dep_name=$(basename "$dep")
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null
            fi
        fi
    done

    # Update ID if it's a dylib
    if [[ "$binary_name" == *.dylib ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null
    fi
}

# ============================================================================
# PASS 1: Collect ALL Homebrew dependencies recursively
# ============================================================================
echo "📦 Pass 1: Scanning for Homebrew dependencies..."

collect_deps() {
    local binary="$1"
    local deps=$(get_deps "$binary")

    for dep in $deps; do
        if is_system_path "$dep"; then
            continue
        fi

        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")

            if should_skip_lib "$lib_name"; then
                continue
            fi

            if grep -q "^$lib_name:" "$HOMEBREW_DEPS_FILE" 2>/dev/null; then
                continue
            fi

            echo "$lib_name:$dep" >> "$HOMEBREW_DEPS_FILE"
            echo "   Found: $lib_name"

            local lib_path=$(find_in_homebrew "$lib_name")
            if [ -n "$lib_path" ] && [ -f "$lib_path" ]; then
                collect_deps "$lib_path"
            fi
        fi
    done
}

# Scan everything in the bundle
find "$APP_PATH/Contents/MacOS" -type f | while read -r bin; do collect_deps "$bin"; done
find "$FRAMEWORKS_DIR" -type f | while read -r bin; do collect_deps "$bin"; done

DEP_COUNT=$(wc -l < "$HOMEBREW_DEPS_FILE" 2>/dev/null | tr -d ' ')
echo "   Found $DEP_COUNT Homebrew dependencies"

# ============================================================================
# PASS 2: Bundle all collected dependencies
# ============================================================================
echo ""
echo "📦 Pass 2: Bundling dependencies..."
while IFS=: read -r lib_name original_path; do
    [ -z "$lib_name" ] && continue
    dest_path="$FRAMEWORKS_DIR/$lib_name"
    if [ ! -f "$dest_path" ]; then
        source_path=$(find_in_homebrew "$lib_name")
        if [ -n "$source_path" ]; then
            echo "   Bundling: $lib_name"
            cp -L "$source_path" "$dest_path"
            chmod 755 "$dest_path"
            xattr -cr "$dest_path" 2>/dev/null
            codesign --remove-signature "$dest_path" 2>/dev/null
        fi
    fi
done < "$HOMEBREW_DEPS_FILE"

# ============================================================================
# PASS 3: Patch ALL binaries
# ============================================================================
echo ""
echo "🔧 Pass 3: Patching binaries..."
find "$APP_PATH/Contents/MacOS" -type f | while read -r bin; do patch_binary "$bin"; done
find "$FRAMEWORKS_DIR" -type f | while read -r bin; do patch_binary "$bin"; done

# ============================================================================
# PASS 4: Verification
# ============================================================================
echo ""
echo "🔍 Pass 4: Verifying..."
FAILED=0
CHECKED=0

verify_binary() {
    local binary="$1"
    local name="$2"
    CHECKED=$((CHECKED + 1))
    local bad_deps=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local" || true)

    if [ -n "$bad_deps" ]; then
        local real_bad=""
        for dep in $bad_deps; do
            if ! should_skip_lib "$(basename "$dep")"; then
                real_bad="$real_bad $dep"
            fi
        done

        if [ -n "$real_bad" ]; then
            echo "   ❌ $name has unresolved dependencies:"
            for dep in $real_bad; do echo "      - $dep"; done
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi
    echo "   ✅ $name"
}

find "$APP_PATH/Contents/MacOS" -type f | while read -r bin; do verify_binary "$bin" "$(basename "$bin")"; done
find "$FRAMEWORKS_DIR" -type f | while read -r bin; do
    if file "$bin" | grep -q "Mach-O"; then
        verify_binary "$bin" "$(basename "$bin")"
    fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED binaries have unresolved dependencies!"
    exit 1
fi
echo "✅ SUCCESS: All $CHECKED binaries verified!"
exit 0
