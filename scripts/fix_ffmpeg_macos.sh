#!/bin/bash
# fix_ffmpeg_macos.sh - Robust macOS Dependency Bundler
#
# This script implements a recursive bundling strategy to ensure all Homebrew
# dependencies are correctly included and patched within the .app bundle.
#
# Principles:
# 1. Clean-room staging: Patching is done in a temporary directory.
# 2. Recursive discovery: Dependencies of dependencies are automatically found.
# 3. LLVM tools: Uses llvm-install_name_tool to handle malformed binaries.
# 4. Zero-tolerance verification: Fails the build if any Homebrew path remains.

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

# 3. Recursive Discovery and Patching Function
# This function finds Homebrew deps, copies them, and patches the binary
patch_binary() {
    local binary="$1"
    local name=$(basename "$binary")

    # Skip if not a Mach-O file
    if ! file "$binary" 2>/dev/null | grep -q "Mach-O"; then
        return 0
    fi

    echo "   🔍 Scanning: $name"

    # Ensure file is writable and unsigned
    chmod +w "$binary"
    codesign --remove-signature "$binary" 2>/dev/null || true

    # Get all dependencies
    local deps=$(otool -L "$binary" | tail -n +2 | awk '{print $1}')

    for dep in $deps; do
        # Check if it's a Homebrew or local library
        if [[ "$dep" == "/opt/homebrew/"* ]] || [[ "$dep" == "/usr/local/"* ]]; then
            local lib_name=$(basename "$dep")
            local dest_lib="$FRAMEWORKS_DIR/$lib_name"

            # A. Bundle the library if we haven't already
            if [ ! -f "$dest_lib" ]; then
                echo "      📦 Bundling: $lib_name"
                if [ -f "$dep" ]; then
                    cp -L "$dep" "$dest_lib"
                else
                    # Fallback search if the path in the binary is slightly off
                    local found_path=$(find "$BREW_PREFIX/opt" -name "$lib_name" -type f | head -n 1)
                    if [ -n "$found_path" ]; then
                        cp -L "$found_path" "$dest_lib"
                    else
                        echo "      ❌ Error: Could not find source for $lib_name"
                        return 1
                    fi
                fi
                # Recursively patch the newly bundled library
                patch_binary "$dest_lib"
            fi

            # B. Relink the binary to use @rpath
            "$PATCH_TOOL" -change "$dep" "@rpath/$lib_name" "$binary" 2>/dev/null || \
            install_name_tool -change "$dep" "@rpath/$lib_name" "$binary" 2>/dev/null || true
        fi
    done

    # C. Set internal ID for dylibs
    if [[ "$name" == *.dylib ]]; then
        "$PATCH_TOOL" -id "@rpath/$name" "$binary" 2>/dev/null || true
    fi

    # D. Add standard RPATHs to ensure @rpath resolution works everywhere
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../.." "$binary" 2>/dev/null || true
}

# 4. Execute Patching Pass
echo "🛠️  Phase 1: Patching App and Frameworks..."
find "$STAGED_APP/Contents/MacOS" -type f | while read -r bin; do patch_binary "$bin"; done
find "$STAGED_APP/Contents/Frameworks" -type f | while read -r bin; do patch_binary "$bin"; done

# 5. Verification Pass
echo "🧪 Phase 2: Zero-Tolerance Verification..."
FAILED=0
while read -r bin; do
    if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
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

# 6. Finalize
echo "✅ Verification Successful!"
echo "🚚 Moving patched app back to build directory..."
rm -rf "$APP_PATH"
cp -R "$STAGED_APP" "$(dirname "$APP_PATH")/"

echo "🎉 Done! App bundle is now self-contained."
