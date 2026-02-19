#!/bin/bash
# fix_ffmpeg_macos.sh - Brute-force recursive dependency bundler
# This script ensures every Homebrew dependency is bundled and patched.

set -e

# Find the .app bundle
APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find build/macos/Build/Products/Release -name "*.app" -type d | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App bundle not found."
    exit 1
fi

echo "☢️  NUCLEAR BUNDLER ACTIVATED"
echo "Target: $APP_PATH"

FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

# Detect the best patching tool available
PATCH_TOOL="install_name_tool"
if command -v llvm-install_name_tool >/dev/null 2>&1; then
    PATCH_TOOL="llvm-install_name_tool"
elif [ -f "/opt/homebrew/opt/llvm/bin/llvm-install_name_tool" ]; then
    PATCH_TOOL="/opt/homebrew/opt/llvm/bin/llvm-install_name_tool"
elif [ -f "/usr/local/opt/llvm/bin/llvm-install_name_tool" ]; then
    PATCH_TOOL="/usr/local/opt/llvm/bin/llvm-install_name_tool"
fi
echo "Using patch tool: $PATCH_TOOL"

# Track processed files to avoid infinite recursion
PROCESSED_FILES=$(mktemp)
trap 'rm -f "$PROCESSED_FILES"' EXIT

# Recursive function to bundle and patch
bundle_and_patch() {
    local target="$1"
    local abs_target=$(realpath "$target")

    # Guard against double-processing
    if grep -q "$abs_target" "$PROCESSED_FILES"; then
        return
    fi
    echo "$abs_target" >> "$PROCESSED_FILES"

    echo "   🔍 Scanning: $(basename "$target")"

    # Ensure file is writable and unsigned
    chmod +w "$target"
    codesign --remove-signature "$target" 2>/dev/null || true

    # Get all Homebrew/local dependencies
    # We parse otool output carefully to get only the paths
    local deps=$(otool -L "$target" | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/homebrew|/usr/local)" || true)

    for dep in $deps; do
        [ -z "$dep" ] && continue

        local lib_name=$(basename "$dep")
        local dest_path="$FRAMEWORKS_DIR/$lib_name"

        # 1. Bundle the dependency if it's missing from the bundle
        if [ ! -f "$dest_path" ]; then
            echo "      📦 Bundling: $lib_name"
            if [ -f "$dep" ]; then
                cp -L "$dep" "$dest_path"
            else
                # Fallback: find the lib in Homebrew opt folders if the path is broken
                local brew_prefix=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
                local found_lib=$(find "$brew_prefix/opt" -name "$lib_name" -type f | head -n 1)
                if [ -n "$found_lib" ]; then
                    cp -L "$found_lib" "$dest_path"
                else
                    echo "      ⚠️  WARNING: Could not find source for $lib_name"
                    continue
                fi
            fi
            chmod 755 "$dest_path"
            # RECURSE: Process the newly bundled library immediately
            bundle_and_patch "$dest_path"
        fi

        # 2. Patch the binary to use the bundled version
        echo "      🔗 Relinking: $lib_name"
        # We try the patch tool, and if it fails (common with malformed FFmpeg binaries),
        # we try to repair the binary with strip before retrying.
        $PATCH_TOOL -change "$dep" "@executable_path/../Frameworks/$lib_name" "$target" || {
            echo "      🔧 Standard patch failed, attempting repair..."
            strip -S "$target" 2>/dev/null || true
            $PATCH_TOOL -change "$dep" "@executable_path/../Frameworks/$lib_name" "$target"
        }
    done

    # 3. Update internal ID for dylibs so they identify as bundled
    if [[ "$target" == *.dylib ]]; then
        $PATCH_TOOL -id "@executable_path/../Frameworks/$(basename "$target")" "$target" 2>/dev/null || true
    fi

    # 4. Add standard RPATHs to ensure resolution works
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$target" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/Frameworks" "$target" 2>/dev/null || true
}

# Phase 1: Initial scan of all binaries in the bundle
echo "🛠️  Phase 1: Processing all binaries..."
# We find all Mach-O files (executables, dylibs, frameworks)
find "$APP_PATH/Contents" -type f | while read -r file; do
    if file "$file" 2>/dev/null | grep -q "Mach-O"; then
        bundle_and_patch "$file"
    fi
done

# Phase 2: Final Verification
echo "🧪 Phase 2: Final Verification..."
FAILED=0
TOTAL=0
while read -r bin; do
    if file "$bin" 2>/dev/null | grep -q "Mach-O"; then
        TOTAL=$((TOTAL + 1))
        # Check for any remaining absolute Homebrew paths
        BAD_DEPS=$(otool -L "$bin" | grep -E "/opt/homebrew|/usr/local" || true)
        if [ -n "$BAD_DEPS" ]; then
            echo "   ❌ FAILED: $(basename "$bin") still has absolute paths:"
            echo "$BAD_DEPS" | sed 's/^/      /'
            FAILED=$((FAILED + 1))
        fi
    fi
done < <(find "$APP_PATH/Contents" -type f)

if [ "$FAILED" -gt 0 ]; then
    echo "❌ Error: $FAILED of $TOTAL binaries failed verification."
    exit 1
fi

echo "✅ SUCCESS: All $TOTAL binaries verified and free of Homebrew paths!"
exit 0
