#!/bin/bash
# Sets CFBundleVersion in the processed Info.plist to the current git commit count.
# Runs as a post-build script (after Info.plist processing, before code signing).

export PATH="${PATH}:/usr/local/bin:/opt/homebrew/bin"

INFOPLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$INFOPLIST" ]; then
    echo "warning: Info.plist not found at $INFOPLIST — skipping build number stamp"
    exit 0
fi

BUILD_NUM=$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)
echo "Stamping CFBundleVersion=$BUILD_NUM in $INFOPLIST"

chmod u+w "$INFOPLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$INFOPLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUM" "$INFOPLIST"
