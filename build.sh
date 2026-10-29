#!/bin/zsh
# Builds Koe.app, installs it to ~/Applications and relaunches it.
# xcodebuild (not swift build) is required to compile MLX's Metal shaders.
set -euo pipefail
cd "$(dirname "$0")"
buildlog=.build/xcodebuild.log
if ! xcodebuild -scheme Koe -destination 'platform=macOS,arch=arm64' -configuration Release \
    -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation build > $buildlog 2>&1; then
    grep -E "error:" $buildlog | sort -u | head -20
    echo "Build failed (full log: $buildlog)"
    exit 1
fi
products=.build/xcode/Build/Products/Release

app=~/Applications/Koe.app
pkill -x Koe 2>/dev/null || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp $products/Koe "$app/Contents/MacOS/"
cp -R $products/*.bundle "$app/Contents/Resources/"  # MLX shaders, tokenizer resources
cp Info.plist "$app/Contents/"
# A stable identity keeps the Accessibility grant across rebuilds; fall back to ad-hoc.
identity=$(security find-identity -p codesigning | grep -q '"Murmur Dev"' && echo "Murmur Dev" || echo -)
codesign --force --deep --sign "$identity" --identifier com.yufei.koe "$app"
echo "Installed $app"
[[ ${1:-} == --no-launch ]] || open "$app"
