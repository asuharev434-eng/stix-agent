#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
app="$project_dir/dist/STIX Agent.app"
models="$HOME/Library/Application Support/STIX Agent/Models"
kit="$project_dir/dist/STIX Agent Offline Kit"
[[ -d "$app" && -d "$models" ]] || { print -u2 'Build the app and import models first'; exit 1; }
/usr/bin/python3 "$project_dir/scripts/verify-owned-models.py" --root "$models"
/usr/bin/codesign --verify --deep --strict "$app"
[[ ! -e "$kit" ]] || { print -u2 "Kit already exists: $kit"; exit 1; }
mkdir -p "$kit"
/bin/cp -cR "$app" "$kit/STIX Agent.app"
/bin/cp -cR "$models" "$kit/Models"
/bin/cp "$project_dir/scripts/verify-owned-models.py" "$kit/verify-owned-models.py"
/bin/cp "$project_dir/scripts/install-offline-kit.sh" "$kit/install.sh"
/usr/bin/python3 "$kit/verify-owned-models.py" --root "$kit/Models"
/usr/bin/codesign --verify --deep --strict "$kit/STIX Agent.app"
print "Offline kit: $kit"
