#!/bin/bash
# fix_ffmpeg_macos.sh - Robust macOS Dependency Bundler (FAT Binary Edition)
#
# This script implements a recursive bundling strategy with architecture splitting
# to ensure all Homebrew dependencies are correctly included and patched, even
# in malformed FAT binaries.

set -euo pipefail

echo "🚀 Starting Robust macOS Dependency Bundling"
echo "==========================================="

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle at '$APP_PATH'"
    exit 1
fi

# 1. Setup Environment and Tools
BREW_PREFIX=$(brew --prefix)
LLVM_PREFIX=$(brew --prefix llvm 2>/dev/null || echo "$BREW_PREFIX/opt/llvm")
PATCH_TOOL="$LLVM_PREFIX/bin/llvm-install_name_tool"

if [ ! -f "$PATCH_TOOL" ]; then
    echo "⚠️  llvm-install_name_tool not found at $PATCH_TOOL"
    echo "   Falling back to system install_name_tool (may fail on FFmpeg binaries)"
    PATCH_TOOL="install_name_tool"
else
    echo "✅ Using LLVM patching tool: $PATCH_TOOL"
fi

# 2. Create Staging Area
STAGING_DIR=$(mktemp -d)
trap "rm -rf '$STAGING_DIR'" EXIT

echo "📂 Staging app for patching: $STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
STAGED_APP="$STAGING_DIR/$(basename "$APP_PATH")"
FRAMEWORKS_DIR="$STAGED_APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# 3. Helper Functions
is_macho() {
    [ -f "$1" ] && file "$1" 2>/dev/null | grep -q "Mach-O"
}

is_fat() {
    lipo -info "$1" 2>/dev/null | grep -q "Architectures in the fat file\|are:"
}

get_archs() {
    lipo -archs "$1" 2>/dev/null
}

# 4. Recursive Discovery and Patching Function
patch_binary() {
    local binary="$1"
    local name=$(basename "$binary")

    if ! is_macho "$binary"; then
        return 0
    fi

    echo "   🔍 Scanning: $name"
    chmod +w "$binary"
    codesign --remove-signature "$binary" 2>/dev/null || true

    if is_fat "$binary"; then
        echo "      📦 FAT binary detected. Splitting architectures..."
        local archs=$(get_archs "$binary")
        local work_dir="$STAGING_DIR/split_$$_$RANDOM"
        mkdir -p "$work_dir"

        local thin_files=""
        for arch in $archs; do
            local thin="$work_dir/$arch"
            if lipo -thin "$arch" -output "$thin" "$binary" 2>/dev/null; then
                patch_thin_binary "$thin"
                thin_files="$thin_files $thin"
            fi
        done

        if [ -n "$thin_files" ]; then
            lipo -create $thin_files -output "$binary"
        fi
        rm -rf "$work_dir"
    else
        patch_thin_binary "$binary"
    fi

    # Add standard RPATHs to ensure @rpath resolution works everywhere
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

patch_thin_binary() {
    local binary="$1"
    local deps=$(otool -L "$binary" | tail -n +2 | awk '{print $1}')

    for dep in $deps; do
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")
            local dest_lib="$FRAMEWORKS_DIR/$lib_name"

            if [ ! -f "$dest_lib" ]; then
                echo "      📦 Bundling: $lib_name"
                if [ -f "$dep" ]; then
                    cp -L "$dep" "$dest_lib"
                else
                    local found_path=$(find "$BREW_PREFIX/opt" -name "$lib_name" -type f | head -n 1)
                    if [ -n "$found_path" ]; then
                        cp -L "$found_path" "$dest_lib"
                    else
                        echo "      ❌ Error: Could not find source for $lib_name"
                        return 1
                    fi
                fi
                patch_binary "$dest_lib"
            fi

            "$PATCH_TOOL" -change "$dep" "@rpath/$lib_name" "$binary" 2>/dev/null || \
            install_name_tool -change "$dep" "@rpath/$lib_name" "$binary" 2>/dev/null || true
        fi
    done

    local name=$(basename "$binary")
    if [[ "$name" == *.dylib ]]; then
        "$PATCH_TOOL" -id "@rpath/$name" "$binary" 2>/dev/null || true
    fi
}

# 5. Execute Patching Pass
echo "🛠️  Phase 1: Patching App and Frameworks..."
find "$STAGED_APP/Contents/MacOS" -type f | while read -r bin; do patch_binary "$bin"; done
find "$STAGED_APP/Contents/Frameworks" -type f | while read -r bin; do patch_binary "$bin"; done

# 6. Verification Pass
echo "🧪 Phase 2: Zero-Tolerance Verification..."
FAILED=0
while read -r bin; do
    if is_macho "$bin"; then
        BAD_DEPS=$(otool -L "$bin" | grep -E "/opt/homebrew|/usr/local" || true)
        if [ -n "$BAD_DEPS" ]; then
            echo "   ❌ Verification Failed: $(basename "$bin") still has absolute paths:"
            echo "$BAD_DEPS" | sed 's/^/      /'
            FAILED=1
        fi
    fi
done < <(find "$STAGED_APP" -type f)

if [ "$FAILED" -ne 0 ]; then
    echo "❌ Error: App bundle verification failed. Build cannot proceed."
    exit 1
fi

# 7. Finalize
echo "✅ Verification Successful!"
echo "🚚 Moving patched app back to build directory..."
rm -rf "$APP_PATH"
cp -R "$STAGED_APP" "$(dirname "$APP_PATH")/"

echo "🎉 Done! App bundle is now self-contained."
