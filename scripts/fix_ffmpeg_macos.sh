#!/bin/bash
# fix_ffmpeg_macos.sh - Fix FFmpeg kit libiconv/zlib issues on macOS

set -e

echo "🔧 Setting up FFmpeg Kit macOS fix..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script is only for macOS."
    exit 1
fi

# Find the package in pub cache
PUB_CACHE_HOME="${PUB_CACHE:-$HOME/.pub-cache}"
PACKAGE_DIR=$(find "$PUB_CACHE_HOME/hosted/pub.dev" -maxdepth 2 -type d -name "ffmpeg_kit_flutter_new_full-*" | head -n 1)

if [ -z "$PACKAGE_DIR" ]; then
    echo "❌ FFmpeg kit package not found in pub cache. Run 'flutter pub get' first."
    exit 1
fi

echo "   Found package at: $PACKAGE_DIR"

# 1. Check for corruption (duplicate links from previous bad fixes)
echo "🔍 Checking for corrupted frameworks..."
NEEDS_RESET=0
if [ -d "$PACKAGE_DIR/macos/Frameworks" ]; then
    for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
        binary_name=$(basename "$framework" .framework)
        binary="$framework/$binary_name"
        if [ -f "$binary" ]; then
            # Check for duplicate libSystem (from "libSystem" patch)
            if [ "$(otool -L "$binary" | grep -c "/usr/lib/libSystem.B.dylib")" -gt 1 ]; then
                echo "🚨 $binary_name has duplicate libSystem links."
                NEEDS_RESET=1
                break
            fi
            # Check for duplicate libiconv (from "patching" patch)
            if [ "$(otool -L "$binary" | grep -c "/usr/lib/libiconv.2.dylib")" -gt 1 ]; then
                echo "🚨 $binary_name has duplicate libiconv links."
                NEEDS_RESET=1
                break
            fi
        fi
    done
fi

if [ "$NEEDS_RESET" -eq 1 ]; then
    echo "🧹 Removing corrupted package..."
    rm -rf "$PACKAGE_DIR"
    echo "⬇️  Running flutter pub get..."
    flutter pub get
    # Re-find package dir
    PACKAGE_DIR=$(find "$PUB_CACHE_HOME/hosted/pub.dev" -maxdepth 2 -type d -name "ffmpeg_kit_flutter_new_full-*" | head -n 1)
    echo "   Package restored at: $PACKAGE_DIR"
fi

# 2. Ensure frameworks exist (download if missing)
if [ ! -d "$PACKAGE_DIR/macos/Frameworks" ]; then
    echo "⬇️  Frameworks not found. Downloading..."
    if [ -f "$PACKAGE_DIR/scripts/setup_macos.sh" ]; then
        pushd "$PACKAGE_DIR/macos" > /dev/null
        chmod +x ../scripts/setup_macos.sh
        ../scripts/setup_macos.sh
        popd > /dev/null
    else
        echo "❌ setup_macos.sh not found in package."
        exit 1
    fi
fi

# 3. Patch frameworks
patch_framework() {
    local framework_path="$1"
    local binary_name=$(basename "$framework_path" .framework)
    local binary="$framework_path/$binary_name"
    
    if [ ! -f "$binary" ]; then
        return
    fi

    echo "   Checking $binary_name..."
    
    # We use FlutterMacOS as a "dummy" target for redundant links.
    # It is guaranteed to be present in the app bundle and NOT linked by FFmpeg.
    # This avoids "duplicate linked dylib" errors and "Library not loaded" errors.
    DUMMY_TARGET="@rpath/FlutterMacOS.framework/FlutterMacOS"

    # Handle libiconv
    if otool -L "$binary" | grep -q "/opt/homebrew/opt/libiconv"; then
        if otool -L "$binary" | grep -q "/usr/lib/libiconv.2.dylib"; then
            echo "      Has system libiconv. Redirecting Homebrew link to FlutterMacOS."
            install_name_tool -change "/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib" "$DUMMY_TARGET" "$binary"
        else
            echo "      No system libiconv. Redirecting Homebrew link to system libiconv."
            install_name_tool -change "/opt/homebrew/opt/libiconv/lib/libiconv.2.dylib" "/usr/lib/libiconv.2.dylib" "$binary"
        fi
    fi

    # Handle zlib
    if otool -L "$binary" | grep -q "/opt/homebrew/opt/zlib"; then
        if otool -L "$binary" | grep -q "/usr/lib/libz.1.dylib"; then
            echo "      Has system zlib. Redirecting Homebrew link to FlutterMacOS."
            install_name_tool -change "/opt/homebrew/opt/zlib/lib/libz.1.dylib" "$DUMMY_TARGET" "$binary"
        else
            echo "      No system zlib. Redirecting Homebrew link to system zlib."
            install_name_tool -change "/opt/homebrew/opt/zlib/lib/libz.1.dylib" "/usr/lib/libz.1.dylib" "$binary"
        fi
    fi
    
    # Verify
    echo "      > Links:"
    otool -L "$binary" | grep -E "FlutterMacOS|libSystem|libiconv|libz" | sed 's/^/        /'
}

echo "🩹 Patching frameworks..."

for framework in "$PACKAGE_DIR/macos/Frameworks/"*.framework; do
    patch_framework "$framework"
done

echo "✅ Fix script completed."
