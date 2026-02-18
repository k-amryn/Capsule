#!/bin/bash
# fix_ffmpeg_macos.sh - Final Robust Patching Script
#
# This script handles both FAT and THIN binaries correctly.
# It ensures that Homebrew dependencies are bundled and patched.

set -uo pipefail

echo "☢️  FFmpeg macOS Post-Build Fix (FINAL ROBUST OPTION)"
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

# Temporary directory for reconstruction
RECON_DIR=$(mktemp -d)
trap "rm -rf '$RECON_DIR'" EXIT

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

is_fat_binary() {
    lipo -info "$1" 2>/dev/null | grep -q "Architectures in the fat file\|are:"
}

# ============================================================================
# Core Logic: Bundling and Patching
# ============================================================================

bundle_dependency() {
    local dep_path="$1"
    local dep_name=$(basename "$dep_path")
    local dest="$FRAMEWORKS_DIR/$dep_name"

    if [ ! -f "$dest" ]; then
        echo "      📦 Bundling: $dep_name"
        local src="$dep_path"
        if [ ! -f "$src" ]; then
            # Try to find it via brew prefix
            local formula=$(echo "$dep_path" | cut -d'/' -f4)
            local prefix=$(brew --prefix "$formula" 2>/dev/null || echo "")
            if [ -n "$prefix" ] && [ -f "$prefix/lib/$dep_name" ]; then
                src="$prefix/lib/$dep_name"
            else
                src=$(find "$BREW_PREFIX" -name "$dep_name" -type f 2>/dev/null | head -n 1)
            fi
        fi

        if [ -n "$src" ] && [ -f "$src" ]; then
            cp -L "$src" "$dest"
            chmod 755 "$dest"
            # Recursively process the newly bundled library
            patch_binary_recursive "$dest"
        else
            echo "      ⚠️  WARNING: Could not find source for $dep_path"
        fi
    fi
}

patch_thin_binary() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    # Remove signature to allow patching
    codesign --remove-signature "$binary" 2>/dev/null || true

    local deps=$(get_deps "$binary")
    for dep in $deps; do
        if is_homebrew_path "$dep"; then
            local dep_name=$(basename "$dep")
            bundle_dependency "$dep"
            if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                # Use the exact dependency string from otool
                install_name_tool -change "$dep" "@rpath/$dep_name" "$binary" 2>/dev/null || true
            fi
        fi
    done

    # Update dylib ID
    if [[ "$binary_name" == *.dylib ]] || [[ "$binary" == *".framework/"* ]]; then
        install_name_tool -id "@rpath/$binary_name" "$binary" 2>/dev/null || true
    fi

    # Add standard RPATHs
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

patch_binary_recursive() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    if ! is_macho "$binary"; then
        return 0
    fi

    echo "   Patching: $binary_name"

    if is_fat_binary "$binary"; then
        echo "      Detected FAT binary, reconstructing..."
        local archs=$(lipo -archs "$binary" 2>/dev/null || echo "")
        local work_dir="$RECON_DIR/patch_${RANDOM}_$$"
        mkdir -p "$work_dir"

        local thin_files=""
        for arch in $archs; do
            local thin_file="$work_dir/$arch"
            if lipo -thin "$arch" -output "$thin_file" "$binary" 2>/dev/null; then
                patch_thin_binary "$thin_file"
                thin_files="$thin_files $thin_file"
            else
                echo "      ⚠️  Failed to extract $arch (skipping slice)"
            fi
        done

        if [ -n "$thin_files" ]; then
            local combined="$work_dir/combined"
            if lipo -create $thin_files -output "$combined" 2>/dev/null; then
                cp "$combined" "$binary"
                chmod 755 "$binary"
                echo "      ✓ Reconstructed and patched successfully"
            else
                echo "      ⚠️  Failed to recombine $binary_name"
            fi
        fi
        rm -rf "$work_dir"
    else
        # Thin binary - direct patch
        patch_thin_binary "$binary"
        echo "      ✓ Patched successfully"
    fi
}

# ============================================================================
# Execution
# ============================================================================

echo ""
echo "🚀 Phase 1: Patching all binaries..."
ALL_BINARIES=$(mktemp)
find "$APP_PATH/Contents" -type f > "$ALL_BINARIES"

while read -r file; do
    if is_macho "$file"; then
        patch_binary_recursive "$file"
    fi
done < "$ALL_BINARIES"

echo ""
echo "🚀 Phase 2: Final sweep of bundled dylibs..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] && patch_binary_recursive "$dylib"
done

# ============================================================================
# Final Verification
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
done < "$ALL_BINARIES"

rm -f "$ALL_BINARIES"

echo ""
echo "=============================================="
if [ "$FAILED" -gt 0 ]; then
    echo "❌ FAILED: $FAILED of $TOTAL binaries have unresolved dependencies"
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified and patched!"
exit 0
