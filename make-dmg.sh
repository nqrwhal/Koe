#!/bin/zsh
# Packages the installed ~/Applications/Koe.app (run ./build.sh first) into dist/Koe.dmg
# with the usual drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")"
app=~/Applications/Koe.app
[[ -d $app ]] || { echo "Build first: ./build.sh"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
mkdir -p dist
hdiutil create -volname "Koe $version" -srcfolder "$staging" -ov -format UDZO "dist/Koe-$version.dmg" >/dev/null
rm -rf "$staging"
echo "Created dist/Koe-$version.dmg ($(du -h "dist/Koe-$version.dmg" | cut -f1))"
