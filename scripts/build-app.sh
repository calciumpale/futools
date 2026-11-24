#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
product="futools.app"
app_path="$PWD/dist/$product"
legacy_app_path="$PWD/dist/Prompt Dock.app"
stage="$PWD/.build/app-bundle"

signing_identity=${PROMPT_DOCK_SIGNING_IDENTITY:-}
for previous_app in "$app_path" "$legacy_app_path"; do
    [[ -z "$signing_identity" ]] || break
    [[ -d "$previous_app" ]] || continue
    signing_identity=$(/usr/bin/codesign -dvv "$previous_app" 2>&1 | /usr/bin/awk '
        /^Authority=/ && !found { sub(/^Authority=/, ""); print; found=1 }
    ') || signing_identity=
done
signing_identity=${signing_identity:--}

swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
bundle="$stage/$product"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" dist
cp "$binary_dir/PromptDock" "$bundle/Contents/MacOS/"
cp Resources/Info.plist "$bundle/Contents/"
/usr/bin/swift scripts/make-icon.swift Resources/AppIcon.png "$stage/AppIcon.iconset" \
    "$bundle/Contents/Resources/MenuBarIcon.png"
/usr/bin/iconutil -c icns "$stage/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$app_path"
printf '%s\n' "$app_path"
