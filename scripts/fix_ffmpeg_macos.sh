#!/bin/bash
# fix_ffmpeg_macos.sh - Reconstruction Option
#
# This script is the ultimate solution for bundling Homebrew dependencies.
# It reconstructs every binary by extracting its architecture slices,
# patching them individually, and then recombining them into a NEW binary.
# This ensures that no "in-place" modification issues or file locking
# can prevent the changes from sticking.

set -uo pipefail

echo "☢️  FFmpeg macOS Post-Build Fix (RECONSTRUCTION OPTION)"
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

# ============================================================================
# Core Logic: Reconstruction and Patching
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
            reconstruct_and_patch "$dest"
        else
            echo "      ⚠️  WARNING: Could not find source for $dep_path"
        fi
    fi
}

reconstruct_and_patch() {
    local binary="$1"
    local binary_name=$(basename "$binary")

    if ! is_macho "$binary"; then
        return 0
    fi

    echo "   Reconstructing: $binary_name"

    # 1. Extract architectures
    local archs=$(lipo -archs "$binary" 2>/dev/null || echo "")
    if [ -z "$archs" ]; then
        echo "      ⚠️  Could not determine architectures for $binary_name"
        return 0
    fi

    local work_dir="$RECON_DIR/patch_${RANDOM}_$$"
    mkdir -p "$work_dir"

    local thin_files=""
    for arch in $archs; do
        local thin_file="$work_dir/$arch"
        if ! lipo -thin "$arch" -output "$thin_file" "$binary" 2>/dev/null; then
            echo "      ⚠️  Failed to extract $arch for $binary_name"
            continue
        fi

        # 2. Patch the thin slice
        chmod 755 "$thin_file"
        codesign --remove-signature "$thin_file" 2>/dev/null || true

        local deps=$(get_deps "$thin_file")
        for dep in $deps; do
            if is_homebrew_path "$dep"; then
                local dep_name=$(basename "$dep")
                bundle_dependency "$dep"
                if [ -f "$FRAMEWORKS_DIR/$dep_name" ]; then
                    install_name_tool -change "$dep" "@rpath/$dep_name" "$thin_file" 2>/dev/null || true
                fi
            fi
        done

        # Update dylib ID
        if [[ "$binary_name" == *.dylib ]] || [[ "$binary" == *".framework/"* ]]; then
            install_name_tool -id "@rpath/$binary_name" "$thin_file" 2>/dev/null || true
        fi

        thin_files="$thin_files $thin_file"
    done

    # 3. Recombine into a NEW binary
    if [ -n "$thin_files" ]; then
        local new_binary="$work_dir/reconstructed"
        if lipo -create $thin_files -output "$new_binary" 2>/dev/null; then
            # Add RPATHs to the new binary
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$new_binary" 2>/dev/null || true
            install_name_tool -add_rpath "@loader_path/Frameworks" "$new_binary" 2>/dev/null || true
            install_name_tool -add_rpath "@loader_path/../Frameworks" "$new_binary" 2>/dev/null || true
            install_name_tool -add_rpath "@loader_path/../../.." "$new_binary" 2>/dev/null || true

            # Move the new binary into place
            cp "$new_binary" "$binary"
            chmod 755 "$binary"
            echo "      ✓ Reconstructed and patched successfully"
        else
            echo "      ⚠️  Failed to recombine $binary_name"
        fi
    fi

    rm -rf "$work_dir"
}

# ============================================================================
# Execution
# ============================================================================

echo ""
echo "🚀 Phase 1: Reconstructing and patching all binaries..."
# Find all Mach-O files first to avoid issues with the bundle changing
ALL_BINARIES=$(mktemp)
find "$APP_PATH/Contents" -type f > "$ALL_BINARIES"

while read -r file; do
    if is_macho "$file"; then
        reconstruct_and_patch "$file"
    fi
done < "$ALL_BINARIES"

echo ""
echo "🚀 Phase 2: Final sweep of bundled dylibs..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -f "$dylib" ] && reconstruct_and_patch "$dylib"
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

echo "✅ SUCCESS: All $TOTAL binaries verified and reconstructed!"
exit 0
