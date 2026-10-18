#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
if [[ "${STIX_USE_EXISTING_BUILD:-0}" != "1" ]]; then
    swift build -c release
fi
binary_dir="$project_dir/.build/release"
[[ -x "$binary_dir/STIXAgent" ]] || { print -u2 "Release binary missing; run without STIX_USE_EXISTING_BUILD"; exit 1; }
app_dir="$project_dir/dist/STIX Agent.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/STIXAgent" "$app_dir/Contents/MacOS/STIXAgent"
for resource_bundle in "$binary_dir"/*.bundle(N); do
    ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
cp "$project_dir/scripts/Info.plist" "$app_dir/Contents/Info.plist"
if [[ -f "$project_dir/Sources/STIXAgent/Resources/AppIcon.icns" ]]; then
    cp "$project_dir/Sources/STIXAgent/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
signing_default="-"
if [[ -f "$project_dir/.signing-identity" ]]; then
    signing_default="$(<"$project_dir/.signing-identity")"
fi
signing_identity="${STIX_SIGN_IDENTITY:-$signing_default}"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --entitlements "$project_dir/scripts/STIXAgent.entitlements" --identifier studio.stix.agent "$app_dir"
else
    codesign --force --sign "$signing_identity" --options runtime --timestamp=none --entitlements "$project_dir/scripts/STIXAgent.entitlements" --identifier studio.stix.agent "$app_dir"
fi
codesign --verify --deep --strict "$app_dir"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    staging_dir="$HOME/Applications/.STIX-Agent-$(uuidgen).app"
    ditto "$app_dir" "$staging_dir"
    codesign --verify --deep --strict "$staging_dir"
    backup_dir=""
    if [[ -d "$HOME/Applications/STIX Agent.app" ]]; then
        backup_dir="$project_dir/dist/previous-$(date +%Y%m%d-%H%M%S).app"
        mv "$HOME/Applications/STIX Agent.app" "$backup_dir"
    fi
    if ! mv "$staging_dir" "$HOME/Applications/STIX Agent.app"; then
        if [[ -n "$backup_dir" ]]; then mv "$backup_dir" "$HOME/Applications/STIX Agent.app"; fi
        exit 1
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/STIX Agent.app"
    print "Installed: $HOME/Applications/STIX Agent.app"
fi
