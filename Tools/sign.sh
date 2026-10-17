#!/bin/bash
# Signs the built binaries with a stable certificate, so the Keychain permission
# ("Always Allow" for the PurifierBar/purifier item) survives rebuilds.
# With ad-hoc signing macOS treats every build as a new app and asks again.
#   sign.sh <file|.app>...
set -euo pipefail
IDENTITY="${PURIFIER_SIGN_IDENTITY:-Tartarus Control Self Signed}"
# Without that certificate (a fresh clone) - ad-hoc signing; macOS will then ask for Keychain
# access again after each rebuild.
if ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
    echo "sign.sh: identity '$IDENTITY' not found - signing ad-hoc" >&2
    IDENTITY="-"
fi
for target in "$@"; do
    codesign --force --sign "$IDENTITY" --identifier "local.purifierbar.$(basename "${target%.app}")" "$target"
done
