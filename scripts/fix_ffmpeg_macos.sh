#!/bin/bash
# fix_ffmpeg_macos.sh - Post-build script to fix FFmpeg library paths in macOS .app bundles
#
# This script handles FAT (universal) binaries by extracting each architecture,
# patching them separately, and recombining them.

set -o pipefail

# Enable debugging output
DEBUG=1
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "   [DEBUG] $*"
    fi
}

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

# Determine Homebrew prefix - be thorough
if [ -d "/opt/homebrew/opt" ]; then
    HOMEBREW_PREFIX="/opt/homebrew"
elif [ -d "/usr/local/opt" ]; then
    HOMEBREW_PREFIX="/usr/local"
else
    # Try to get it from brew command
    HOMEBREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
fi
echo "   Homebrew prefix: $HOMEBREW_PREFIX"

# Pre-flight check: Verify all required Homebrew libraries are available
echo ""
echo "📋 Pre-flight check: Verifying Homebrew libraries..."

REQUIRED_FORMULAS=(
    "zlib"
    "fontconfig"
    "freetype"
    "fribidi"
    "harfbuzz"
    "glib"
    "graphite2"
    "libiconv"
    "pcre2"
    "gettext"
    "openssl@3"
    "srt"
)

MISSING_LIBS=0
for formula in "${REQUIRED_FORMULAS[@]}"; do
    prefix=$(brew --prefix "$formula" 2>/dev/null)
    if [ -n "$prefix" ] && [ -d "$prefix/lib" ]; then
        # Count actual dylib files (not symlinks to system)
        lib_count=$(find "$prefix/lib" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "$lib_count" -gt 0 ]; then
            echo "   ✓ $formula: $prefix/lib ($lib_count dylibs)"
        else
            # Check for symlinks that aren't pointing to system
            real_libs=$(ls "$prefix/lib"/*.dylib 2>/dev/null | while read f; do
                if [ -L "$f" ]; then
                    target=$(readlink "$f")
                    if [[ "$target" != "/usr/lib/"* ]] && [[ "$target" != "/System/"* ]]; then
                        echo "$f"
                    fi
                fi
            done | wc -l | tr -d ' ')
            if [ "$real_libs" -gt 0 ]; then
                echo "   ✓ $formula: $prefix/lib (via symlinks)"
            else
                echo "   ⚠️  $formula: libs may be symlinks to system"
            fi
        fi
    else
        echo "   ✗ $formula: NOT FOUND"
        MISSING_LIBS=$((MISSING_LIBS + 1))
    fi
done

if [ "$MISSING_LIBS" -gt 0 ]; then
    echo ""
    echo "   ⚠️  $MISSING_LIBS required libraries not found!"
    echo "   Run: brew install zlib fontconfig freetype fribidi harfbuzz graphite2 glib pcre2 gettext openssl@3 srt libiconv"
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
TEMP_DIR=$(mktemp -d)
mkdir -p "$FRAMEWORKS_DIR"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ============================================================================
# Helper Functions
# ============================================================================

is_macho() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q "Mach-O"
}

is_fat_binary() {
    local info=$(lipo -info "$1" 2>/dev/null)
    echo "$info" | grep -q "Architectures in the fat file" || echo "$info" | grep -q "are:"
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

# Map library names to Homebrew formula names
lib_to_formula() {
    local lib_name="$1"
    case "$lib_name" in
        libz.*) echo "zlib" ;;
        libpng*) echo "libpng" ;;
        libfontconfig*) echo "fontconfig" ;;
        libfreetype*) echo "freetype" ;;
        libfribidi*) echo "fribidi" ;;
        libharfbuzz*) echo "harfbuzz" ;;
        libglib-*) echo "glib" ;;
        libgraphite2*) echo "graphite2" ;;
        libiconv*) echo "libiconv" ;;
        libpcre2*) echo "pcre2" ;;
        libintl*) echo "gettext" ;;
        libexpat*) echo "expat" ;;
        libbrotli*) echo "brotli" ;;
        libbz2*) echo "bzip2" ;;
        liblzma*) echo "xz" ;;
        libssl*|libcrypto*) echo "openssl@3" ;;
        libsrt*) echo "srt" ;;
        *) echo "" ;;
    esac
}

# Check if a file is a real Homebrew library (not a symlink to system)
is_valid_homebrew_lib() {
    local lib_path="$1"
    [ ! -f "$lib_path" ] && return 1

    # If it's a symlink, check where it points
    if [ -L "$lib_path" ]; then
        local target=$(readlink "$lib_path")
        # Reject if it points to system paths
        if [[ "$target" == "/usr/lib/"* ]] || [[ "$target" == "/System/"* ]]; then
            return 1
        fi
    fi
    return 0
}

# Find the actual versioned library file (e.g., libz.1.3.1.dylib for libz.1.dylib)
find_versioned_lib() {
    local dir="$1"
    local lib_name="$2"

    # Extract base name pattern (e.g., "libz" from "libz.1.dylib")
    local base_pattern=$(echo "$lib_name" | sed -E 's/\.[0-9]+\.dylib$//')

    # Look for versioned files like libz.1.3.1.dylib
    local versioned=$(ls "$dir"/${base_pattern}.[0-9]*.[0-9]*.[0-9]*.dylib 2>/dev/null | head -n 1)
    if [ -n "$versioned" ] && [ -f "$versioned" ]; then
        echo "$versioned"
        return 0
    fi

    # Try pattern like libz.1.3.dylib
    versioned=$(ls "$dir"/${base_pattern}.[0-9]*.[0-9]*.dylib 2>/dev/null | grep -v "^${dir}/${lib_name}$" | head -n 1)
    if [ -n "$versioned" ] && [ -f "$versioned" ]; then
        echo "$versioned"
        return 0
    fi

    return 1
}

find_lib_source() {
    local lib_name="$1"

    # First, try the direct path based on known formulas
    local formula=$(lib_to_formula "$lib_name")
    if [ -n "$formula" ]; then
        local prefix=$(brew --prefix "$formula" 2>/dev/null)
        if [ -n "$prefix" ] && [ -d "$prefix/lib" ]; then
            # Check if the exact file exists and is valid
            if is_valid_homebrew_lib "$prefix/lib/$lib_name"; then
                echo "$prefix/lib/$lib_name"
                return 0
            fi

            # Try to find a versioned variant
            local versioned=$(find_versioned_lib "$prefix/lib" "$lib_name")
            if [ -n "$versioned" ]; then
                debug "Using versioned lib: $versioned instead of $lib_name"
                echo "$versioned"
                return 0
            fi
        fi
    fi

    # Fallback to hardcoded paths
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
        if is_valid_homebrew_lib "$dir/$lib_name"; then
            echo "$dir/$lib_name"
            return 0
        fi

        # Try versioned variant
        local versioned=$(find_versioned_lib "$dir" "$lib_name")
        if [ -n "$versioned" ]; then
            debug "Using versioned lib: $versioned instead of $lib_name"
            echo "$versioned"
            return 0
        fi
    done

    # Final fallback: search all of Homebrew for actual files (not symlinks)
    local found=$(find "$HOMEBREW_PREFIX/opt" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    if [ -n "$found" ] && is_valid_homebrew_lib "$found"; then
        echo "$found"
        return 0
    fi

    # Last resort: search Cellar directly
    find "$HOMEBREW_PREFIX/Cellar" -name "$lib_name" -type f 2>/dev/null | head -n 1
}

# ============================================================================
# Bundle a library (copies from Homebrew to Frameworks)
# ============================================================================

bundle_lib() {
    local lib_name="$1"
    local dest="$FRAMEWORKS_DIR/$lib_name"

    if [ -f "$dest" ]; then
        return 0
    fi

    local src=$(find_lib_source "$lib_name")
    if [ -n "$src" ] && [ -f "$src" ]; then
        local src_basename=$(basename "$src")
        echo "      Bundling: $lib_name from $src"

        # If source has a different name (versioned), copy it with the expected name
        if cp -L "$src" "$dest" 2>&1; then
            chmod 755 "$dest"
            xattr -cr "$dest" 2>/dev/null || true
            codesign --remove-signature "$dest" 2>/dev/null || true

            # Update the dylib's ID to match the expected name
            install_name_tool -id "@rpath/$lib_name" "$dest" 2>/dev/null || true

            debug "Successfully bundled $lib_name"
            return 0
        else
            echo "      ⚠️  Failed to copy $lib_name"
            return 1
        fi
    else
        echo "      ⚠️  Could not find: $lib_name in Homebrew (searched $HOMEBREW_PREFIX)"
        return 1
    fi
}

# ============================================================================
# Patch a single thin binary (modifies in place)
# ============================================================================

patch_thin_binary_inplace() {
    local binary="$1"

    chmod 755 "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    local deps=$(get_deps "$binary")
    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")
            debug "Found Homebrew dep: $dep -> $dep_name"
            bundle_lib "$dep_name"
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                debug "Patching: $dep -> @rpath/$dep_name"
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>&1 | grep -v "warning" || true
            else
                echo "      ⚠️  Cannot patch $dep - $dep_name not in Frameworks"
            fi
        fi
    done

    # Update dylib ID if applicable
    local binary_name=$(basename "$binary")
    if [[ "$binary_name" == *.dylib ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null || true
    fi
}

# ============================================================================
# Patch a FAT binary by extracting, patching each arch, and recombining
# ============================================================================

patch_fat_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")
    local work_dir="$TEMP_DIR/fat_${RANDOM}_$$"
    mkdir -p "$work_dir"

    echo "   Processing FAT binary: $binary_name"

    # Get architectures
    local archs=$(get_archs "$binary")
    if [ -z "$archs" ]; then
        echo "      ⚠️  Could not determine architectures, trying direct patch"
        patch_thin_binary_inplace "$binary"
        rm -rf "$work_dir"
        return 0
    fi

    echo "      Architectures: $archs"

    # First pass: collect all Homebrew dependencies from all slices and bundle them
    for arch in $archs; do
        local thin="$work_dir/${arch}"
        if lipo -thin "$arch" -output "$thin" "$binary" 2>/dev/null; then
            local deps=$(get_deps "$thin")
            for dep in $deps; do
                if is_homebrew_path "$dep"; then
                    local dep_name=$(basename "$dep")
                    bundle_lib "$dep_name"
                fi
            done
        fi
    done

    # Second pass: extract, patch, and prepare thin binaries
    local thin_binaries=""
    local all_success=true

    for arch in $archs; do
        local thin="$work_dir/${arch}"

        # Re-extract if needed (in case first pass failed)
        if [ ! -f "$thin" ]; then
            if ! lipo -thin "$arch" -output "$thin" "$binary" 2>&1; then
                echo "      ⚠️  Failed to extract $arch slice"
                all_success=false
                continue
            fi
        fi

        chmod 755 "$thin"
        codesign --remove-signature "$thin" 2>/dev/null || true

        # Patch this slice
        local deps=$(get_deps "$thin")
        local patched_count=0
        for dep in $deps; do
            if is_homebrew_path "$dep"; then
                local dep_name=$(basename "$dep")
                if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                    debug "  [$arch] Patching: $dep -> @rpath/$dep_name"
                    if install_name_tool -change "$dep" "@rpath/$dep_name" "$thin" 2>&1; then
                        patched_count=$((patched_count + 1))
                    else
                        echo "      ⚠️  install_name_tool failed for $dep in $arch slice"
                    fi
                else
                    echo "      ⚠️  [$arch] Missing bundled lib: $dep_name"
                fi
            fi
        done
        debug "  [$arch] Patched $patched_count dependencies"

        # Update ID if dylib
        if [[ "$binary_name" == *.dylib ]]; then
            install_name_tool -id "@rpath/$binary_name" "$thin" 2>/dev/null || true
        fi

        thin_binaries="$thin_binaries $thin"
    done

    # Recombine architectures
    if [ -n "$thin_binaries" ]; then
        local combined="$work_dir/combined"
        debug "Recombining: lipo -create $thin_binaries -output $combined"
        local lipo_output
        if lipo_output=$(lipo -create $thin_binaries -output "$combined" 2>&1); then
            debug "Copying combined binary back to $binary"
            if cp "$combined" "$binary" 2>&1; then
                chmod 755 "$binary"
                echo "      ✓ Patched successfully"

                # Verify the patch worked
                local remaining=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local/opt" | head -3)
                if [ -n "$remaining" ]; then
                    echo "      ⚠️  Warning: Some deps still unpatched:"
                    echo "$remaining" | head -3 | sed 's/^/         /'
                fi
            else
                echo "      ⚠️  Failed to copy patched binary back"
            fi
        else
            echo "      ⚠️  Failed to recombine architectures: $lipo_output"
        fi
    else
        echo "      ⚠️  No thin binaries to recombine"
    fi

    rm -rf "$work_dir"
}

# ============================================================================
# Main patch function
# ============================================================================

patch_binary() {
    local binary="$1"

    if ! is_macho "$binary"; then
        return 0
    fi

    # Make writable
    chmod 755 "$binary" 2>/dev/null || true
    xattr -cr "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    if is_fat_binary "$binary"; then
        patch_fat_binary "$binary"
    else
        local binary_name=$(basename "$binary")
        echo "   Processing thin binary: $binary_name"
        patch_thin_binary_inplace "$binary"
    fi

    # Add RPATHs (ignore errors if already present)
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

# ============================================================================
# Collect all Mach-O files
# ============================================================================

collect_binaries() {
    find "$APP_PATH/Contents" -type f -print0 | while IFS= read -r -d '' file; do
        if is_macho "$file"; then
            echo "$file"
        fi
    done
}

# ============================================================================
# PASS 1: Initial patching of all binaries
# ============================================================================

echo ""
echo "📦 Pass 1: Patching all binaries..."

while IFS= read -r binary; do
    patch_binary "$binary"
done < <(collect_binaries)

# ============================================================================
# PASS 2: Patch any newly bundled libraries
# ============================================================================

echo ""
echo "📦 Pass 2: Patching bundled libraries..."

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    patch_binary "$dylib"
done

# ============================================================================
# PASS 3: Another pass to catch recursive dependencies
# ============================================================================

echo ""
echo "📦 Pass 3: Final dependency check..."

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue

    # Check if it still has Homebrew deps
    bad_deps=$(get_deps "$dylib" | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)
    if [ -n "$bad_deps" ]; then
        echo "   Re-patching: $(basename "$dylib")"
        patch_binary "$dylib"
    fi
done

# Also re-check frameworks
while IFS= read -r binary; do
    bad_deps=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)
    if [ -n "$bad_deps" ]; then
        echo "   Re-patching: $(basename "$binary")"
        patch_binary "$binary"
    fi
done < <(collect_binaries)

# ============================================================================
# PASS 4: Verification
# ============================================================================

echo ""
echo "🔍 Pass 4: Verification..."

FAILED=0
TOTAL=0

while IFS= read -r binary; do
    TOTAL=$((TOTAL + 1))
    name=$(basename "$binary")

    bad_deps=$(get_deps "$binary" | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)

    if [ -n "$bad_deps" ]; then
        echo "   ❌ $name has unresolved Homebrew dependencies:"
        for dep in $bad_deps; do
            echo "      - $dep"
        done
        FAILED=$((FAILED + 1))
    fi
done < <(collect_binaries)

echo ""
echo "=============================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified!"
exit 0
