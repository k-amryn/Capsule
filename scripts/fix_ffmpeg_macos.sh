#!/bin/bash
#
# fix_ffmpeg_macos.sh - Nuclear option for fixing Homebrew dependencies
#
# This script takes a brute-force approach to ensure ALL Homebrew dependencies
# are properly bundled and patched in the macOS app bundle.
#

set -uo pipefail

echo "🔧 FFmpeg macOS Post-Build Fix (Nuclear Mode)"
echo "=============================================="

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
TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

mkdir -p "$FRAMEWORKS_DIR"

# ============================================================================
# STEP 1: Bundle ALL required libraries from Homebrew FIRST
# ============================================================================

echo ""
echo "📦 STEP 1: Bundling all required Homebrew libraries..."

# Function to get formula name for a library
get_formula_for_lib() {
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
        libssl*) echo "openssl@3" ;;
        libcrypto*) echo "openssl@3" ;;
        libsrt*) echo "srt" ;;
        libexpat*) echo "expat" ;;
        libbrotli*) echo "brotli" ;;
        *) echo "" ;;
    esac
}

bundle_library() {
    local lib_name="$1"
    local dest="$FRAMEWORKS_DIR/$lib_name"

    # Skip if already bundled
    if [ -f "$dest" ]; then
        echo "   ✓ $lib_name (already bundled)"
        return 0
    fi

    local formula
    formula=$(get_formula_for_lib "$lib_name")
    local src=""

    if [ -n "$formula" ]; then
        local prefix
        prefix=$(brew --prefix "$formula" 2>/dev/null || echo "")
        if [ -n "$prefix" ] && [ -d "$prefix/lib" ]; then
            # Try exact match first
            if [ -f "$prefix/lib/$lib_name" ]; then
                src="$prefix/lib/$lib_name"
            else
                # Try to find versioned variant (e.g., libz.1.3.1.dylib for libz.1.dylib)
                local base
                base=$(echo "$lib_name" | sed 's/\.[0-9]*\.dylib$/./')
                src=$(find "$prefix/lib" -maxdepth 1 -name "${base}*dylib" -type f 2>/dev/null | head -n 1)
            fi
        fi
    fi

    # Fallback: search common locations
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        for search_dir in \
            "$BREW_PREFIX/opt/${formula:-unknown}/lib" \
            "$BREW_PREFIX/lib"
        do
            if [ -f "$search_dir/$lib_name" ]; then
                src="$search_dir/$lib_name"
                break
            fi
        done
    fi

    # Final fallback: find anywhere in Homebrew
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        src=$(find "$BREW_PREFIX" -name "$lib_name" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$src" ] && [ -f "$src" ]; then
        echo "   Bundling: $lib_name from $src"
        cp -L "$src" "$dest"
        chmod 755 "$dest"
        xattr -cr "$dest" 2>/dev/null || true
        codesign --remove-signature "$dest" 2>/dev/null || true
        # Set the dylib ID
        install_name_tool -id "@rpath/$lib_name" "$dest" 2>/dev/null || true
        return 0
    else
        echo "   ⚠️  Could not find: $lib_name"
        return 1
    fi
}

# List of required libraries to bundle
REQUIRED_LIBS="
libz.1.dylib
libpng16.16.dylib
libfontconfig.1.dylib
libfreetype.6.dylib
libfribidi.0.dylib
libharfbuzz.0.dylib
libglib-2.0.0.dylib
libgraphite2.3.dylib
libiconv.2.dylib
libpcre2-8.0.dylib
libintl.8.dylib
libssl.3.dylib
libcrypto.3.dylib
libsrt.1.5.dylib
"

# Bundle all known required libraries
for lib_name in $REQUIRED_LIBS; do
    [ -z "$lib_name" ] && continue
    bundle_library "$lib_name" || true
done

# ============================================================================
# STEP 2: Scan all binaries and bundle any additional dependencies found
# ============================================================================

echo ""
echo "📦 STEP 2: Scanning for additional dependencies..."

scan_and_bundle() {
    local binary="$1"

    if ! file "$binary" 2>/dev/null | grep -q "Mach-O"; then
        return 0
    fi

    local deps
    deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

    for dep in $deps; do
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/opt/"* ]] || [[ "$dep" == "/usr/local/Cellar/"* ]]; then
            local dep_name
            dep_name=$(basename "$dep")
            bundle_library "$dep_name" || true
        fi
    done
}

# Scan all files in the bundle
find "$APP_PATH/Contents" -type f | while read -r file; do
    scan_and_bundle "$file"
done

# Also scan bundled dylibs for their dependencies
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    scan_and_bundle "$dylib"
done

# ============================================================================
# STEP 3: Patch all Mach-O binaries (handling FAT binaries properly)
# ============================================================================

echo ""
echo "🔧 STEP 3: Patching all binaries..."

patch_single_arch_binary() {
    local binary="$1"
    local deps

    chmod 755 "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

    for dep in $deps; do
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/opt/"* ]] || [[ "$dep" == "/usr/local/Cellar/"* ]]; then
            local dep_name
            dep_name=$(basename "$dep")
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
            fi
        fi
    done
}

patch_binary() {
    local binary="$1"
    local binary_name
    binary_name=$(basename "$binary")

    if ! file "$binary" 2>/dev/null | grep -q "Mach-O"; then
        return 0
    fi

    # Make writable
    chmod 755 "$binary" 2>/dev/null || true
    xattr -cr "$binary" 2>/dev/null || true
    codesign --remove-signature "$binary" 2>/dev/null || true

    # Check if FAT binary
    local lipo_info
    lipo_info=$(lipo -info "$binary" 2>/dev/null || echo "")

    if echo "$lipo_info" | grep -q "Architectures in the fat file\|are:"; then
        # FAT binary - extract, patch each arch, recombine
        echo "   Patching FAT binary: $binary_name"

        local archs
        archs=$(lipo -archs "$binary" 2>/dev/null || echo "")

        if [ -z "$archs" ]; then
            echo "      ⚠️  Could not determine architectures, trying direct patch"
            patch_single_arch_binary "$binary"
            return 0
        fi

        local work_dir="$TEMP_DIR/patch_$$_$RANDOM"
        mkdir -p "$work_dir"

        local thin_files=""
        local all_ok=true

        for arch in $archs; do
            local thin_file="$work_dir/$arch"

            if ! lipo -thin "$arch" -output "$thin_file" "$binary" 2>/dev/null; then
                echo "      ⚠️  Failed to extract $arch"
                all_ok=false
                continue
            fi

            chmod 755 "$thin_file"
            codesign --remove-signature "$thin_file" 2>/dev/null || true

            # Patch this architecture
            local deps
            deps=$(otool -L "$thin_file" 2>/dev/null | tail -n +2 | awk '{print $1}' || echo "")

            for dep in $deps; do
                if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/opt/"* ]] || [[ "$dep" == "/usr/local/Cellar/"* ]]; then
                    local dep_name
                    dep_name=$(basename "$dep")
                    if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                        install_name_tool -change "$dep" "@rpath/$dep_name" "$thin_file" 2>/dev/null || true
                    fi
                fi
            done

            # Update dylib ID if applicable
            if [[ "$binary_name" == *.dylib ]]; then
                install_name_tool -id "@rpath/$binary_name" "$thin_file" 2>/dev/null || true
            fi

            thin_files="$thin_files $thin_file"
        done

        # Recombine
        if [ -n "$thin_files" ]; then
            local combined="$work_dir/combined"
            if lipo -create $thin_files -output "$combined" 2>/dev/null; then
                if cp "$combined" "$binary" 2>/dev/null; then
                    chmod 755 "$binary"
                    echo "      ✓ Patched successfully"
                else
                    echo "      ⚠️  Failed to copy back"
                fi
            else
                echo "      ⚠️  Failed to recombine"
            fi
        fi

        rm -rf "$work_dir"
    else
        # Thin binary - direct patch
        echo "   Patching thin binary: $binary_name"
        patch_single_arch_binary "$binary"
    fi

    # Add RPATHs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

# Patch all binaries in the bundle
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        patch_binary "$file"
    fi
done

# ============================================================================
# STEP 4: Patch bundled dylibs (they may have their own dependencies)
# ============================================================================

echo ""
echo "🔧 STEP 4: Patching bundled dylibs..."

for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] || continue
    patch_binary "$dylib"
done

# ============================================================================
# STEP 5: Second pass - ensure everything is patched
# ============================================================================

echo ""
echo "🔧 STEP 5: Second pass verification and patching..."

needs_patching() {
    local binary="$1"
    otool -L "$binary" 2>/dev/null | grep -qE "/opt/homebrew|/usr/local/opt|/usr/local/Cellar"
}

# Check and re-patch anything that still has Homebrew paths
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        if needs_patching "$file"; then
            echo "   Re-patching: $(basename "$file")"
            patch_binary "$file"
        fi
    fi
done

# ============================================================================
# STEP 6: Final verification
# ============================================================================

echo ""
echo "🔍 STEP 6: Final verification..."

FAILED=0
TOTAL=0

while IFS= read -r file; do
    if ! file "$file" 2>/dev/null | grep -q "Mach-O"; then
        continue
    fi

    TOTAL=$((TOTAL + 1))
    name=$(basename "$file")

    bad_deps=$(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "/opt/homebrew|/usr/local/opt|/usr/local/Cellar" || true)

    if [ -n "$bad_deps" ]; then
        echo "   ❌ $name has unresolved Homebrew dependencies:"
        echo "$bad_deps" | while read -r dep; do
            echo "      - $dep"
        done
        FAILED=$((FAILED + 1))
    fi
done < <(find "$APP_PATH/Contents" -type f)

echo ""
echo "=============================================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified!"
exit 0
