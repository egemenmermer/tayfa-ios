#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
# Local preparation only: no export, upload, account login or provisioning updates.
mode="${1:---unsigned}"
if [[ "$mode" != '--unsigned' && "$mode" != '--signed' ]]; then
  print -u2 'Usage: ./scripts/build-beta.sh [--unsigned|--signed]'
  exit 2
fi
xcodegen generate --spec project.yml
version=$(sed -n 's/.*MARKETING_VERSION: //p' project.yml)
# Read generated build metadata instead of maintaining a second build number.
build=$(sed -n "s/.*CURRENT_PROJECT_VERSION: '\([0-9]*\)'.*/\1/p" project.yml)
archive="$PWD/build/ROOMS-$version-$build-Release.xcarchive"
args=(CODE_SIGNING_ALLOWED=NO)
if [[ "$mode" == '--signed' ]]; then
  : "${ROOMS_STORE_PROFILE:?Set the existing App Store profile UUID/name locally.}"
  args=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual
    'CODE_SIGN_IDENTITY=Apple Distribution' "PROVISIONING_PROFILE_SPECIFIER=$ROOMS_STORE_PROFILE")
fi
xcodebuild -project ROOMS.xcodeproj -scheme ROOMS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -derivedDataPath "$PWD/build/BetaDerivedData" "${args[@]}" archive
python3 scripts/verify-beta.py "$archive"
print "Local Release archive: $archive ($mode). Not exported, uploaded or Apple-validated."
