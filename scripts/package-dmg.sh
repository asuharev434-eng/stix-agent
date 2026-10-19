#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/STIX Agent.app"
[[ -d "$app_dir" ]] || { print -u2 "App bundle missing: run ./scripts/build-app.sh first"; exit 1; }
codesign --verify --deep --strict "$app_dir"

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
architectures="$(lipo -archs "$app_dir/Contents/MacOS/STIXAgent")"
[[ "$architectures" == "arm64" ]] || { print -u2 "Expected arm64-only app, got: $architectures"; exit 1; }

output="$project_dir/dist/STIX-Agent-${version}-macOS-arm64.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp/}stix-agent-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app_dir" "$stage/STIX Agent.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname 'STIX Agent' -srcfolder "$stage" -format UDZO -ov "$output"
hdiutil verify -quiet "$output"
shasum -a 256 "$output"
print "Installer: $output"
