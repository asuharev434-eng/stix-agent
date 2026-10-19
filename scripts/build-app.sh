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
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/STIXAgent" "$app_dir/Contents/MacOS/STIXAgent"
for resource_bundle in "$binary_dir"/*.bundle(N); do
    ditto "$resource_bundle" "$app_dir/Contents/Resources/${resource_bundle:t}"
done
if [[ "${STIX_BUNDLE_TEXT:-0}" == "1" ]]; then
    "$project_dir/scripts/build-llama.sh"
    staging_dir="${STIX_MODEL_STAGING:-$HOME/Library/Caches/STIXAgentBuild/Models}"
    model_file="$staging_dir/Qwen3-4B-Q4_K_M.gguf"
    expected_hash="ab27b9bfa375a178d6cba48f3ad892b94b7739659dcc7aae8058ce0ffed6b328"
    [[ -f "$model_file" ]] || { print -u2 "Missing verified built-in text model: $model_file"; exit 1; }
    actual_hash="$(/usr/bin/shasum -a 256 "$model_file" | /usr/bin/awk '{print $1}')"
    [[ "$actual_hash" == "$expected_hash" ]] || { print -u2 "Built-in text model SHA-256 mismatch"; exit 1; }
    mkdir -p "$app_dir/Contents/Frameworks" "$app_dir/Contents/Resources/Models" "$app_dir/Contents/Resources/Licenses"
    ditto "$project_dir/dist/native/Frameworks" "$app_dir/Contents/Frameworks"
    cp "$model_file" "$app_dir/Contents/Resources/Models/"
    cp "$project_dir/models/builtin-text.json" "$app_dir/Contents/Resources/Models/manifest.json"
    cp "$project_dir/dist/native/llama.cpp-LICENSE.txt" "$app_dir/Contents/Resources/Licenses/"
    cp "$project_dir/models/Qwen3-LICENSE.txt" "$app_dir/Contents/Resources/Licenses/"
fi
if [[ "${STIX_BUNDLE_IMAGE:-0}" == "1" ]]; then
    image_stage="${STIX_IMAGE_STAGING:-$HOME/Library/Caches/STIXAgentBuild/CoreML-SD15-Palettized}"
    /usr/bin/python3 "$project_dir/scripts/stage-coreml-image.py" --output "$image_stage" --verify-only
    mkdir -p "$app_dir/Contents/Resources/Models" "$app_dir/Contents/Resources/Licenses"
    ditto "$image_stage" "$app_dir/Contents/Resources/Models/CoreML-SD15-Palettized"
    cp "$project_dir/models/CreativeML-OpenRAIL-M.txt" "$app_dir/Contents/Resources/Licenses/"
    cp "$project_dir/models/Apple-CoreML-StableDiffusion-LICENSE.txt" "$app_dir/Contents/Resources/Licenses/"
fi
cp "$project_dir/scripts/Info.plist" "$app_dir/Contents/Info.plist"
if [[ -f "$project_dir/Sources/STIXAgent/Resources/AppIcon.icns" ]]; then
    cp "$project_dir/Sources/STIXAgent/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
signing_default="-"
if [[ -f "$project_dir/.signing-identity" ]]; then
    signing_default="$(<"$project_dir/.signing-identity")"
fi
signing_identity="${STIX_SIGN_IDENTITY:-$signing_default}"
timestamp_option="--timestamp=none"
if [[ -n "${STIX_NOTARY_PROFILE:-}" ]]; then timestamp_option="--timestamp"; fi
for library in "$app_dir"/Contents/Frameworks/lib*.dylib(N); do
    [[ -L "$library" ]] && continue
    if [[ "$signing_identity" == "-" ]]; then
        codesign --force --sign - "$library"
    else
        codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" "$library"
    fi
done
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --entitlements "$project_dir/scripts/STIXAgent.entitlements" --identifier studio.stix.agent "$app_dir"
else
    codesign --force --sign "$signing_identity" --options runtime "$timestamp_option" --entitlements "$project_dir/scripts/STIXAgent.entitlements" --identifier studio.stix.agent "$app_dir"
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
    print "Installed: $HOME/Applications/STIX Agent.app"
fi
