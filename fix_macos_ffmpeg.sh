#!/bin/bash
echo "Fixing FFmpeg frameworks..."

# Look in Flutter symlinks
SEARCH_DIR="macos/Flutter/ephemeral/.symlinks/plugins/ffmpeg_kit_flutter_new/macos/Frameworks"

if [ ! -d "$SEARCH_DIR" ]; then
    echo "Directory not found: $SEARCH_DIR"
    # Try finding it broadly
    SEARCH_DIR=$(find macos -type d -name "Frameworks" | grep "ffmpeg_kit_flutter_new" | head -n 1)
fi

if [ -z "$SEARCH_DIR" ]; then
    echo "Could not find FFmpeg frameworks directory."
    exit 1
fi

echo "Searching in $SEARCH_DIR"

find "$SEARCH_DIR" -name "*.framework" | while read fw; do
    name=$(basename "$fw" .framework)
    binary="$fw/$name"
    if [ ! -f "$binary" ]; then
        binary="$fw/Versions/A/$name"
    fi
    
    if [ -f "$binary" ]; then
        echo "Checking $binary"
        if otool -L "$binary" 2>/dev/null | grep -q "/opt/homebrew/opt/zlib/lib/libz.1.dylib"; then
            echo "Patching $binary"
            install_name_tool -change /opt/homebrew/opt/zlib/lib/libz.1.dylib /usr/lib/libz.1.dylib "$binary"
            
            # Verify
            if otool -L "$binary" | grep -q "/opt/homebrew/opt/zlib/lib/libz.1.dylib"; then
                echo "Failed to patch $binary"
            else
                echo "Successfully patched $binary"
            fi
        else
             echo "Binary $binary does not need patching."
        fi
    fi
done
echo "Done."