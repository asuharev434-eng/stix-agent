#!/bin/zsh
set -euo pipefail
kit="${0:A:h}"
models="$HOME/Library/Application Support/STIX Agent/Models"
app="$HOME/Applications/STIX Agent.app"
[[ -d "$kit/STIX Agent.app" && -d "$kit/Models" ]] || { print -u2 'Incomplete offline kit'; exit 1; }
/usr/bin/python3 "$kit/verify-owned-models.py" --root "$kit/Models"
/usr/bin/codesign --verify --deep --strict "$kit/STIX Agent.app"
[[ ! -e "$models" ]] || { print -u2 "Existing models must be preserved and merged separately: $models"; exit 1; }
[[ ! -e "$app" ]] || { print -u2 "Existing app must be preserved and updated separately: $app"; exit 1; }
mkdir -p "${models:h}" "${app:h}"
staged_models="${models:h}/.Models-$(uuidgen)"
staged_app="${app:h}/.STIX-Agent-$(uuidgen).app"
trap 'rm -rf "$staged_models" "$staged_app"' EXIT
/usr/bin/ditto "$kit/Models" "$staged_models"
/usr/bin/python3 "$kit/verify-owned-models.py" --root "$staged_models"
/usr/bin/ditto "$kit/STIX Agent.app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
/bin/mv "$staged_models" "$models"
/bin/mv "$staged_app" "$app"
print "Installed offline: $app"
