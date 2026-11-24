#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
product="Prompt Dock.app"
app_path="$PWD/dist/$product"
stage="$PWD/.build/app-bundle"

signing_identity=${PROMPT_DOCK_SIGNING_IDENTITY:-}
if [[ -z "$signing_identity" && -d "$app_path" ]]; then
    # Keeping the certificate also keeps macOS permissions tied to the same app.
    signing_identity=$(/usr/bin/codesign -dvv "$app_path" 2>&1 | /usr/bin/awk '
        /^Authority=/ && !found { sub(/^Authority=/, ""); print; found=1 }
    ') || signing_identity=
fi
signing_identity=${signing_identity:--}

swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
bundle="$stage/$product"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" dist
cp "$binary_dir/PromptDock" "$bundle/Contents/MacOS/"
cp Resources/Info.plist "$bundle/Contents/"
/usr/bin/swift scripts/make-icon.swift "$stage/AppIcon.iconset"
/usr/bin/iconutil -c icns "$stage/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$app_path"
printf '%s\n' "$app_path"
