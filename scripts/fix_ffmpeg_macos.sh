#!/bin/bash
# fix_ffmpeg_macos.sh - Brute-force architecture-specific patching
#
# This script ensures all Homebrew dependencies are bundled and patched.
# It uses an aggressive approach by patching each architecture slice explicitly.

set -uo pipefail

echo "☢️  FFmpeg macOS Post-Build Fix (BRUTE FORCE MODE)"
echo "====================================================="

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Could not find .app bundle"
    exit 1
fi

# Detect Homebrew and LLVM
BREW_PREFIX=$(brew --prefix)
LLVM_PREFIX=$(brew --prefix llvm 2>/dev/null || echo "$BREW_PREFIX/opt/llvm")
LLVM_TOOL="$LLVM_PREFIX/bin/llvm-install_name_tool"

if [ -f "$LLVM_TOOL" ]; then
    echo "✅ Using LLVM tool: $LLVM_TOOL"
    PATCH_TOOL="$LLVM_TOOL"
else
    echo "⚠️  LLVM tool not found, using system install_name_tool"
    PATCH_TOOL="install_name_tool"
fi

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Ensure everything is writable
chmod -R +w "$APP_PATH"

# Helper: Get architectures of a binary
get_archs() {
    lipo -archs "$1" 2>/dev/null || echo ""
}

# Helper: Get Homebrew dependencies of a binary
get_brew_deps() {
    otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E "/opt/homebrew|/usr/local" || true
}

# 1. Recursive Bundling Pass
echo "📦 Phase 1: Collecting all Homebrew dependencies..."
STILL_COLLECTING=true
while [ "$STILL_COLLECTING" = true ]; do
    STILL_COLLECTING=false
    while read -r bin; do
        DEPS=$(get_brew_deps "$bin")
        for dep in $DEPS; do
            LIB_NAME=$(basename "$dep")
            DEST="$FRAMEWORKS_DIR/$LIB_NAME"
            if [ ! -f "$DEST" ]; then
                echo "   Bundling: $LIB_NAME"
                if [ -f "$dep" ]; then
                    cp -L "$dep" "$DEST"
                else
                    SRC=$(find "$BREW_PREFIX/opt" -name "$LIB_NAME" -type f | head -n 1)
                    if [ -n "$SRC" ]; then
                        cp -L "$SRC" "$DEST"
                    else
                        echo "   ⚠️  Could not find source for $LIB_NAME"
                        continue
                    fi
                fi
                chmod 755 "$DEST"
                STILL_COLLECTING=true
            fi
        done
    done < <(find "$APP_PATH/Contents" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' sh {} \; -print)
done

# 2. Brute-Force Patching Pass
echo "🛠️  Phase 2: Patching all binaries (Architecture-Specific)..."
while read -r bin; do
    NAME=$(basename "$bin")
    ARCHS=$(get_archs "$bin")
    DEPS=$(get_brew_deps "$bin")

    if [ -n "$DEPS" ]; then
        echo "   Patching: $NAME"
        # Remove signature to allow modification
        codesign --remove-signature "$bin" 2>/dev/null || true

        for dep in $DEPS; do
            LIB_NAME=$(basename "$dep")
            # Patch every architecture slice explicitly
            for arch in $ARCHS; do
                "$PATCH_TOOL" -arch "$arch" -change "$dep" "@rpath/$LIB_NAME" "$bin" 2>/dev/null || true
            done
            # Also patch without -arch as a fallback
            "$PATCH_TOOL" -change "$dep" "@rpath/$LIB_NAME" "$bin" 2>/dev/null || true
        done

        # Set ID if it's a dylib
        if [[ "$NAME" == *.dylib ]]; then
            "$PATCH_TOOL" -id "@rpath/$NAME" "$bin" 2>/dev/null || true
        fi
    fi

    # Add standard RPATHs to everything
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$bin" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$bin" 2>/dev/null || true
done < <(find "$APP_PATH/Contents" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' sh {} \; -print)

# 3. Final Verification
echo "🧪 Phase 3: Final Verification..."
FAILED=0
while read -r bin; do
    BAD_DEPS=$(get_brew_deps "$bin")
    if [ -n "$BAD_DEPS" ]; then
        echo "   ❌ FAILED: $(basename "$bin") still has Homebrew paths:"
        echo "$BAD_DEPS" | sed 's/^/      /'
        FAILED=$((FAILED + 1))
    fi
done < <(find "$APP_PATH/Contents" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O' sh {} \; -print)

if [ "$FAILED" -gt 0 ]; then
    echo "❌ Error: $FAILED binaries failed verification."
    exit 1
fi

echo "✅ SUCCESS: All binaries patched and verified!"
