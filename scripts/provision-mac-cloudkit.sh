#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
xcodebuild -project "$project_dir/macOS/STIXAgentSigning.xcodeproj" \
    -scheme STIXAgentSigning -configuration Debug -destination 'platform=macOS' \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    -derivedDataPath "$project_dir/.build/cloudkit-signing" build >&2
profile="$project_dir/.build/cloudkit-signing/Build/Products/Debug/STIXAgentSigning.app/Contents/embedded.provisionprofile"
[[ -f "$profile" ]] || { print -u2 "Xcode did not create a CloudKit provisioning profile"; exit 1; }
print -r -- "$profile"
