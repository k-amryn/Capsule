#!/bin/bash
set -euo pipefail

# fix_ffmpeg_macos.sh - Final Robust Solution
# Handles __LINKEDIT corruption using LLVM tools and architecture splitting.

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

echo "🚀 Starting Robust macOS Dependency Bundling"
echo "Target: $APP_PATH"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# 1. Find LLVM tools aggressively
# LLVM tools are required to handle malformed binaries that Apple's tools reject.
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
LLVM_BIN="$BREW_PREFIX/opt/llvm/bin"
PATCH_TOOL="install_name_tool"

if [ -f "$LLVM_BIN/llvm-install_name_tool" ]; then
    PATCH_TOOL="$LLVM_BIN/llvm-install_name_tool"
    echo "✅ Using LLVM patch tool: $PATCH_TOOL"
elif command -v llvm-install_name_tool >/dev/null 2>&1; then
    PATCH_TOOL=$(command -v llvm-install_name_tool)
    echo "✅ Using LLVM patch tool from PATH: $PATCH_TOOL"
else
    echo "⚠️  llvm-install_name_tool not found, using system tool (expect failures on FFmpeg libs)"
fi

# 2. Helper Functions
get_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/homebrew|/usr/local)" || true
}

is_macho() {
    [ -f "$1" ] && file -b "$1" | grep -q "Mach-O"
}

# 3. Patching Function (Thin Binary)
patch_binary() {
    local bin="$1"
    local name=$(basename "$bin")

    chmod +w "$bin"
    codesign --remove-signature "$bin" 2>/dev/null || true

    # Add header padding to allow modifications (GitHub AI suggestion)
    install_name_tool -headerpad_max_install_names "$bin" 2>/dev/null || true

    local deps=$(get_deps "$bin")
    for dep in $deps; do
        local lib_name=$(basename "$dep")
        local dest="$FRAMEWORKS_DIR/$lib_name"

        # Bundle if missing
        if [ ! -f "$dest" ]; then
            echo "      📦 Bundling: $lib_name"
            if [ -f "$dep" ]; then
                cp -L "$dep" "$dest"
            else
                local src=$(find "$BREW_PREFIX/opt" -name "$lib_name" -type f | head -n 1)
                if [ -n "$src" ]; then
                    cp -L "$src" "$dest"
                else
                    echo "      ⚠️  Could not find source for $lib_name"
                    continue
                fi
            fi
            chmod 755 "$dest"
            # Recurse into the newly bundled library
            process_fat_binary "$dest"
        fi

        # Relink using the robust tool
        echo "      🔗 Relinking: $lib_name"
        if ! "$PATCH_TOOL" -change "$dep" "@rpath/$lib_name" "$bin" 2>/dev/null; then
            echo "      🔧 Patch failed, attempting repair..."
            # Repair attempts for corrupted __LINKEDIT segments
            strip -S "$bin" 2>/dev/null || true

            if ! "$PATCH_TOOL" -change "$dep" "@rpath/$lib_name" "$bin"; then
                echo "      ❌ FAILED to patch $name"
                exit 1
            fi
        fi
    done

    # Update ID for dylibs
    if [[ "$name" == *.dylib ]] || [[ "$bin" == *".framework/"* ]]; then
        "$PATCH_TOOL" -id "@rpath/$name" "$bin" 2>/dev/null || true
    fi

    # Add standard RPATHs to ensure resolution works
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$bin" 2>/dev/null || true
}

# 4. FAT Binary Handling
# We process FAT binaries by splitting them, patching slices, and recombining.
# This is the most reliable way to handle __LINKEDIT corruption.
process_fat_binary() {
    local bin="$1"
    local name=$(basename "$bin")

    if ! lipo -info "$bin" 2>/dev/null | grep -q "Architectures in the fat file\|are:"; then
        patch_binary "$bin"
        return
    fi

    echo "   📦 FAT binary: $name. Splitting..."
    local archs=$(lipo -archs "$bin")
    local work_dir=$(mktemp -d)
    local thin_files=""

    for arch in $archs; do
        local thin="$work_dir/$arch"
        if lipo -thin "$arch" -output "$thin" "$bin" 2>/dev/null; then
            patch_binary "$thin"
            thin_files="$thin_files $thin"
        else
            echo "      ⚠️  Failed to extract $arch slice"
        fi
    done

    if [ -n "$thin_files" ]; then
        lipo -create $thin_files -output "$bin"
        echo "      ✓ Recombined $name"
    fi
    rm -rf "$work_dir"
}

# 5. Main Execution
echo "🛠️  Phase 1: Processing all binaries..."
# Find all binaries and process them
ALL_BINARIES=$(mktemp)
find "$APP_PATH/Contents" -type f > "$ALL_BINARIES"

while read -r file; do
    if is_macho "$file"; then
        process_fat_binary "$file"
    fi
done < "$ALL_BINARIES"

echo "🧪 Phase 2: Final Verification..."
FAILED=0
while read -r bin; do
    if is_macho "$bin"; then
        BAD_DEPS=$(otool -L "$bin" | grep -E "/opt/homebrew|/usr/local" || true)
        if [ -n "$BAD_DEPS" ]; then
            echo "   ❌ FAILED: $(basename "$bin") still has absolute paths:"
            echo "$BAD_DEPS" | sed 's/^/      /'
            FAILED=$((FAILED + 1))
        fi
    fi
done < "$ALL_BINARIES"

rm -f "$ALL_BINARIES"

if [ "$FAILED" -gt 0 ]; then
    echo "❌ Error: Verification failed for $FAILED binaries."
    exit 1
fi

echo "✅ SUCCESS: App bundle is now self-contained and patched!"
