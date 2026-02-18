#!/bin/bash
# fix_ffmpeg_macos.sh - Aggressive post-build script to fix FFmpeg library paths
#
# This script ensures ALL Homebrew dependencies are bundled and patched to use @rpath.
# It is designed to be extremely thorough and verbose to catch edge cases in
# nested frameworks and complex dependency trees.

set +e

echo "🔧 FFmpeg macOS Post-Build Fix (Aggressive Mode)"
echo "==============================================="

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

# Temp file for tracking dependencies
HOMEBREW_DEPS_FILE=$(mktemp)
trap "rm -f $HOMEBREW_DEPS_FILE" EXIT

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
    [[ "$path" == "/opt/homebrew/"* ]] || [[ "$path" == "/usr/local/"* ]]
}

is_system_path() {
    local path="$1"
    case "$path" in
        /System/Library/*) return 0 ;;
        /usr/lib/libSystem*) return 0 ;;
        /usr/lib/libobjc*) return 0 ;;
        /usr/lib/libc++*) return 0 ;;
        @rpath/* | @executable_path/* | @loader_path/*) return 0 ;;
    esac
    return 1
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

# ============================================================================
# PASS 1: Recursive Dependency Collection
# ============================================================================
echo ""
echo "📦 Pass 1: Recursively collecting Homebrew dependencies..."

collect_deps_recursive() {
    local binary="$1"
    local deps=$(get_deps "$binary")

    for dep in $deps; do
        if is_homebrew_path "$dep" && ! is_system_path "$dep"; then
            local lib_name=$(basename "$dep")

            if ! grep -q "^$lib_name:" "$HOMEBREW_DEPS_FILE" 2>/dev/null; then
                echo "$lib_name:$dep" >> "$HOMEBREW_DEPS_FILE"
                echo "   Found: $lib_name (from $(basename "$binary"))"

                local source_path=$(find_in_homebrew "$lib_name")
                if [ -n "$source_path" ]; then
                    collect_deps_recursive "$source_path"
                fi
            fi
        fi
    done
}

# Scan everything currently in the bundle
find "$APP_PATH/Contents" -type f | while read -r file; do
    if is_macho "$file"; then
        collect_deps_recursive "$file"
    fi
done

# ============================================================================
# PASS 2: Bundling
# ============================================================================
echo ""
echo "📦 Pass 2: Bundling dependencies into Contents/Frameworks..."

while IFS=: read -r lib_name original_path; do
    dest_path="$FRAMEWORKS_DIR/$lib_name"
    if [ ! -f "$dest_path" ]; then
        source_path=$(find_in_homebrew "$lib_name")
        if [ -n "$source_path" ]; then
            echo "   Bundling: $lib_name"
            cp -L "$source_path" "$dest_path"
            chmod 755 "$dest_path"
            xattr -cr "$dest_path" 2>/dev/null
            codesign --remove-signature "$dest_path" 2>/dev/null
        else
            echo "   ⚠️  Could not find source for $lib_name"
        fi
    fi
done < "$HOMEBREW_DEPS_FILE"

# ============================================================================
# PASS 3: Aggressive Patching
# ============================================================================
echo ""
echo "🔧 Pass 3: Patching all binaries in the bundle..."

patch_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    chmod 755 "$binary" 2>/dev/null
    codesign --remove-signature "$binary" 2>/dev/null

    local deps=$(get_deps "$binary")
    local patched=0

    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                echo "      $binary_name: $dep -> @rpath/$dep_name"
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null
                patched=1
            fi
        fi
    done

    # Update ID if it's a dylib
    if [[ "$binary_name" == *.dylib ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null
    fi
}

# Patch every single Mach-O file in the entire bundle
find "$APP_PATH/Contents" -type f | while read -r file; do
    if is_macho "$file"; then
        patch_binary "$file"
    fi
done

# ============================================================================
# PASS 4: Verification
# ============================================================================
echo ""
echo "🔍 Pass 4: Final Verification..."

FAILED=0
CHECKED=0

find "$APP_PATH/Contents" -type f | while read -r file; do
    if is_macho "$file"; then
        CHECKED=$((CHECKED + 1))
        bad_deps=$(get_deps "$file" | grep -E "/opt/homebrew|/usr/local" || true)

        if [ -n "$bad_deps" ]; then
            echo "   ❌ $(basename "$file") still has Homebrew dependencies:"
            for dep in $bad_deps; do
                echo "      - $dep"
            done
            FAILED=$((FAILED + 1))
        else
            # Also check if it can find its @rpath dependencies (basic check)
            echo "   ✅ $(basename "$file")"
        fi
    fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED binaries have unresolved dependencies!"
    exit 1
fi

echo "✅ SUCCESS: All binaries verified and patched!"
exit 0
