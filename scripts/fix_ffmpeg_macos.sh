#!/bin/bash
# fix_ffmpeg_macos.sh - Fix FFmpeg kit libiconv/zlib issues on macOS

set -e

echo "🔧 Setting up FFmpeg Kit macOS fix..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is only for macOS."
    exit 1
fi

# 1. Clean up corrupted binaries from previous "patching" attempts
# The previous fix attempted to modify the binaries using install_name_tool,
# which caused "duplicate linked dylib" errors because the binaries were modified
# to point to /usr/lib while also having other references.
# We need to ensure we are using the ORIGINAL, UNMODIFIED binaries from the package.

echo "🔍 Checking for corrupted/patched frameworks in pub cache..."

# Find the package in pub cache
# We look for the directory starting with ffmpeg_kit_flutter_new_full
PUB_CACHE_HOME="${PUB_CACHE:-$HOME/.pub-cache}"
PACKAGE_DIR=$(find "$PUB_CACHE_HOME/hosted/pub.dev" -maxdepth 2 -type d -name "ffmpeg_kit_flutter_new_full-*" | head -n 1)

if [ -z "$PACKAGE_DIR" ]; then
    echo "⚠️  FFmpeg kit package not found in pub cache. It might be downloaded later."
else
    echo "   Found package at: $PACKAGE_DIR"
    
    # Check if Frameworks exist (they might not if pod install hasn't run)
    FRAMEWORK_TEST_FILE="$PACKAGE_DIR/macos/Frameworks/libavdevice.framework/libavdevice"
    
    if [ -f "$FRAMEWORK_TEST_FILE" ]; then
        # Check if it links to /opt/homebrew/opt/libiconv...
        # The original UNMODIFIED binary MUST link to the Homebrew path.
        # If it doesn't, it means it was patched (likely to /usr/lib/...), which causes duplicates.
        if ! otool -L "$FRAMEWORK_TEST_FILE" | grep -q "/opt/homebrew/opt/libiconv"; then
            echo "🚨 Detected corrupted/patched frameworks!"
            echo "   The frameworks are missing the expected Homebrew paths, which means they were patched."
            echo "   This causes 'duplicate linked dylib' errors."
            echo "   Removing corrupted package to force fresh download..."
            rm -rf "$PACKAGE_DIR"
            
            echo "⬇️  Re-downloading package..."
            flutter pub get
            echo "✅ Package re-downloaded."
        else
            echo "✅ Frameworks appear to be clean (unpatched)."
        fi
    else
        echo "ℹ️  Frameworks not yet downloaded in package (normal for fresh install)."
    fi
fi

# 2. Apply the Symlink Fix
# Instead of modifying binaries, we create symlinks at the expected Homebrew paths pointing to system libraries.

ICONV_PATH="/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib"
ZLIB_PATH="/opt/homebrew/opt/zlib/lib/libz.1.dylib"
SYSTEM_ICONV="/usr/lib/libiconv.2.dylib"
SYSTEM_ZLIB="/usr/lib/libz.1.dylib"

echo "🔗 Checking/Creating symlinks..."

create_symlink() {
    local target="$1"
    local source="$2"
    local dir=$(dirname "$target")

    if [ -L "$target" ]; then
        current_dest=$(readlink "$target")
        if [ "$current_dest" == "$source" ]; then
            echo "   ✅ $target -> $source (OK)"
            return
        fi
        echo "   ⚠️  $target points to $current_dest, updating..."
    elif [ -f "$target" ]; then
        echo "   ⚠️  $target is a real file. Skipping to avoid breaking real Homebrew."
        return
    fi

    if [ ! -d "$dir" ]; then
        echo "   Creating directory: $dir"
        sudo mkdir -p "$dir"
    fi

    echo "   Linking $target -> $source"
    sudo ln -sf "$source" "$target"
}

echo "   This may require sudo password:"
create_symlink "$ICONV_PATH" "$SYSTEM_ICONV"
create_symlink "$ZLIB_PATH" "$SYSTEM_ZLIB"

echo "✅ Fix script completed."
