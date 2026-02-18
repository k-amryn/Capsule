#!/bin/bash
# fix_ffmpeg_macos.sh - Post-build script to fix FFmpeg library paths in macOS .app bundles
#
# This script handles FAT (universal) binaries by extracting each architecture,
# patching them separately, and recombining them.

set +e

echo "🔧 FFmpeg macOS Post-Build Fix"
echo "=============================="

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
else
    HOMEBREW_PREFIX="/usr/local"
fi
echo "   Homebrew prefix: $HOMEBREW_PREFIX"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
TEMP_DIR=$(mktemp -d)
mkdir -p "$FRAMEWORKS_DIR"

trap "rm -rf $TEMP_DIR" EXIT

# ============================================================================
# Helper Functions
# ============================================================================

is_macho() {
    [ -f "$1" ] && file "$1" | grep -q "Mach-O"
}

is_fat_binary() {
    lipo -info "$1" 2>/dev/null | grep -q "Architectures in the fat file"
}

get_archs() {
    lipo -archs "$1" 2>/dev/null
}

get_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

is_homebrew_path() {
    [[ "$1" == "/opt/homebrew/"* ]] || [[ "$1" == "/usr/local/opt/"* ]] || [[ "$1" == "/usr/local/Cellar/"* ]]
}

find_lib_source() {
    local lib_name="$1"
    local search_paths=(
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
        "$HOMEBREW_PREFIX/opt/srt/lib"
        "$HOMEBREW_PREFIX/lib"
    )

    for dir in "${search_paths[@]}"; do
        if [ -f "$dir/$lib_name" ]; then
            echo "$dir/$lib_name"
            return 0
        fi
    done

    # Fallback: search all of Homebrew
    find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1
}

# ============================================================================
# Bundle a library
# ============================================================================

bundle_lib() {
    local lib_name="$1"
    local dest="$FRAMEWORKS_DIR/$lib_name"

    if [ -f "$dest" ]; then
        return 0
    fi

    local src=$(find_lib_source "$lib_name")
    if [ -n "$src" ] && [ -f "$src" ]; then
        echo "   Bundling: $lib_name"
        cp -L "$src" "$dest"
        chmod 755 "$dest"
        xattr -cr "$dest" 2>/dev/null
        codesign --remove-signature "$dest" 2>/dev/null
        return 0
    else
        echo "   ⚠️  Could not find: $lib_name"
        return 1
    fi
}

# ============================================================================
# Patch a THIN (single-arch) binary
# ============================================================================

patch_thin_binary() {
    local binary="$1"
    local deps=$(get_deps "$binary")

    chmod 755 "$binary" 2>/dev/null
    codesign --remove-signature "$binary" 2>/dev/null

    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")
            bundle_lib "$dep_name"
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null
            fi
        fi
    done

    # Update dylib ID if applicable
    local binary_name=$(basename "$binary")
    if [[ "$binary_name" == *.dylib ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null
    fi
}

# ============================================================================
# Patch a FAT (universal) binary by splitting, patching each arch, recombining
# ============================================================================

patch_fat_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")
    local work_dir="$TEMP_DIR/fat_$$_$RANDOM"
    mkdir -p "$work_dir"

    echo "   Processing FAT binary: $binary_name"

    # Get architectures
    local archs=$(get_archs "$binary")
    if [ -z "$archs" ]; then
        echo "      Could not determine architectures"
        rm -rf "$work_dir"
        return 1
    fi

    echo "      Architectures: $archs"

    # First, collect all Homebrew dependencies from all slices
    local all_deps=""
    for arch in $archs; do
        local thin="$work_dir/${arch}"
        if lipo -thin "$arch" -output "$thin" "$binary" 2>/dev/null; then
            local deps=$(get_deps "$thin")
            for dep in $deps; do
                if is_homebrew_path "$dep"; then
                    local dep_name=$(basename "$dep")
                    if [[ ! " $all_deps " =~ " $dep_name " ]]; then
                        all_deps="$all_deps $dep_name"
                    fi
                fi
            done
        fi
    done

    # Bundle all dependencies first
    for dep_name in $all_deps; do
        bundle_lib "$dep_name"
    done

    # Now extract, patch, and prepare for recombine
    local thin_binaries=""
    local success=1

    for arch in $archs; do
        local thin="$work_dir/${arch}"
        if [ ! -f "$thin" ]; then
            if ! lipo -thin "$arch" -output "$thin" "$binary" 2>/dev/null; then
                echo "      Failed to extract $arch"
                success=0
                break
            fi
        fi

        chmod 755 "$thin"
        codesign --remove-signature "$thin" 2>/dev/null

        # Patch this slice
        local deps=$(get_deps "$thin")
        for dep in $deps; do
            if is_homebrew_path "$dep"; then
                local dep_name=$(basename "$dep")
                if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                    install_name_tool -change "$dep" "@rpath/$dep_name" "$thin" 2>/dev/null
                fi
            fi
        done

        # Update ID if dylib
        local binary_base=$(basename "$binary")
        if [[ "$binary_base" == *.dylib ]]; then
            install_name_tool -id "@rpath/$binary_base" "$thin" 2>/dev/null
        fi

        thin_binaries="$thin_binaries $thin"
    done

    # Recombine
    if [ "$success" -eq 1 ] && [ -n "$thin_binaries" ]; then
        local combined="$work_dir/combined"
        if lipo -create $thin_binaries -output "$combined" 2>/dev/null; then
            cp "$combined" "$binary"
            chmod 755 "$binary"
            echo "      ✓ Patched successfully"
        else
            echo "      ⚠️  Failed to recombine"
        fi
    fi

    rm -rf "$work_dir"
}

# ============================================================================
# Main patch function - handles both FAT and thin binaries
# ============================================================================

patch_binary() {
    local binary="$1"

    if ! is_macho "$binary"; then
        return 0
    fi

    chmod 755 "$binary" 2>/dev/null
    xattr -cr "$binary" 2>/dev/null
    codesign --remove-signature "$binary" 2>/dev/null

    if is_fat_binary "$binary"; then
        patch_fat_binary "$binary"
    else
        local binary_name=$(basename "$binary")
        echo "   Processing thin binary: $binary_name"
        patch_thin_binary "$binary"
    fi

    # Add RPATHs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null
}

# ============================================================================
# PASS 1: Find and patch all binaries
# ============================================================================

echo ""
echo "📦 Pass 1: Patching all binaries..."

# Use process substitution to avoid subshell issues
while IFS= read -r -d '' file; do
    patch_binary "$file"
done < <(find "$APP_PATH/Contents" -type f -print0)

# ============================================================================
# PASS 2: Second pass to catch any newly bundled libraries
# ============================================================================

echo ""
echo "📦 Pass 2: Patching bundled libraries..."

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    patch_binary "$dylib"
done

# ============================================================================
# PASS 3: Verification
# ============================================================================

echo ""
echo "🔍 Pass 3: Verification..."

FAILED=0
TOTAL=0

verify_binary() {
    local binary="$1"
    local name=$(basename "$binary")

    if ! is_macho "$binary"; then
        return 0
    fi

    TOTAL=$((TOTAL + 1))

    local bad_deps=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)

    if [ -n "$bad_deps" ]; then
        echo "   ❌ $name has unresolved Homebrew dependencies:"
        for dep in $bad_deps; do
            echo "      - $dep"
        done
        FAILED=$((FAILED + 1))
        return 1
    fi

    return 0
}

while IFS= read -r -d '' file; do
    verify_binary "$file"
done < <(find "$APP_PATH/Contents" -type f -print0)

echo ""
echo "=============================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified!"
exit 0
