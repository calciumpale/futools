#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ $# -le 1 ]] || fail "Usage: $0 [version]"
bundle_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
version=${1:-$bundle_version}
version=${version#v}
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "The release version must be a macOS version such as 1.3."
[[ "$version" == "$bundle_version" ]] || fail "The requested version must match CFBundleShortVersionString ($bundle_version)."

minimum_macos=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)
[[ "$minimum_macos" =~ ^[0-9]+\.[0-9]+$ ]] || fail "LSMinimumSystemVersion must contain a macOS major and minor version."
executable=$(/usr/bin/plutil -extract CFBundleExecutable raw Resources/Info.plist)
[[ "$executable" == PromptDock ]] || fail "The bundle executable must match the PromptDock target."

mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/futools-release.XXXXXX")
trap 'rm -r "$stage"' EXIT
bundle="$stage/futools.app"
binary="$bundle/Contents/MacOS/$executable"
archive_name="futools-v$version-macOS-universal.zip"
archive="$stage/$archive_name"
release="$PWD/dist/$archive_name"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)

mkdir -p "$stage/source" "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp -X Sources/PromptDock/*.swift "$stage/source/"
cp -X Resources/Info.plist "$bundle/Contents/Info.plist"
cp -X Resources/AppIcon.png "$stage/AppIcon.png"
cp -X scripts/make-icon.swift "$stage/make-icon.swift"

for arch in arm64 x86_64; do
    printf 'Building %s for macOS %s+\n' "$arch" "$minimum_macos"
    /usr/bin/xcrun swiftc -sdk "$sdk" -target "$arch-apple-macosx$minimum_macos" \
        -swift-version 5 -module-name PromptDock -file-prefix-map "$stage=." \
        -parse-as-library -O "$stage/source/"*.swift -o "$stage/PromptDock-$arch"
done
/usr/bin/lipo -create "$stage/PromptDock-arm64" "$stage/PromptDock-x86_64" -output "$binary"

/usr/bin/swift "$stage/make-icon.swift" "$stage/AppIcon.png" "$stage/AppIcon.iconset" \
    "$bundle/Contents/Resources/MenuBarIcon.png"
/usr/bin/iconutil -c icns "$stage/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"

verify_bundle() {
    local app=$1 target arch build minimum platform
    target="$app/Contents/MacOS/$executable"
    /usr/bin/lipo "$target" -verify_arch arm64 x86_64
    for arch in arm64 x86_64; do
        build=$(/usr/bin/vtool -arch "$arch" -show-build "$target")
        minimum=$(printf '%s\n' "$build" | /usr/bin/awk '$1 == "minos" { print $2 }')
        platform=$(printf '%s\n' "$build" | /usr/bin/awk '$1 == "platform" { print $2 }')
        [[ "$platform" == MACOS && "$minimum" == "$minimum_macos" ]] ||
            fail "Unexpected $arch deployment target: $platform $minimum"
    done
    /usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
    /usr/bin/codesign --verify --strict --all-architectures "$app"
}

verify_bundle "$bundle"
# Fixed timestamps keep ZIP metadata independent of the time the package was built.
/usr/bin/find "$bundle" -exec /usr/bin/touch -t 202001010000 {} +
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle" "$archive"

expected_entries=$(printf '%s\n' \
    'futools.app/Contents/Info.plist' \
    "futools.app/Contents/MacOS/$executable" \
    'futools.app/Contents/Resources/AppIcon.icns' \
    'futools.app/Contents/Resources/MenuBarIcon.png' \
    'futools.app/Contents/_CodeSignature/CodeResources' | /usr/bin/sort)
archive_entries=$(/usr/bin/unzip -Z1 "$archive" | /usr/bin/awk '!/\/$/' | /usr/bin/sort)
[[ "$archive_entries" == "$expected_entries" ]] || fail "The ZIP contains an unexpected file or is missing a release resource."

mkdir "$stage/unpacked"
/usr/bin/ditto -x -k "$archive" "$stage/unpacked"
verify_bundle "$stage/unpacked/futools.app"
if [[ -L "$release" || ( -e "$release" && ! -f "$release" ) ]]; then
    fail "The release destination is not a regular file: $release"
fi
mv -f "$archive" "$release"
printf '%s\n' "$release"
/usr/bin/shasum -a 256 "$release"
