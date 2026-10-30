#!/bin/zsh
# Packages the installed ~/Applications/Koe.app (run ./build.sh first) for a release:
# dist/Koe.zip for install.sh, and dist/Koe-<version>.dmg with the drag-to-Applications layout.
set -euo pipefail
cd "$(dirname "$0")"
app=~/Applications/Koe.app
[[ -d $app ]] || { echo "Build first: ./build.sh"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
mkdir -p dist

ditto -c -k --keepParent "$app" dist/Koe.zip

staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Koe $version" -srcfolder "$staging" -ov -format UDZO "dist/Koe-$version.dmg" >/dev/null 2>&1
rm -rf "$staging"
echo "Created dist/Koe.zip and dist/Koe-$version.dmg"
