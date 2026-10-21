#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --spec project.yml
# Compile for an actual iPhone. Xcode 26.6's catalog compiler requires a
# simulator runtime even for device PNG catalogs; omit only that catalog
# for this development PoC, then install ordinary icons while signing.
xcodebuild -project ROOMS.xcodeproj -target ROOMS -configuration Debug \
  -sdk iphoneos -arch arm64 CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$PWD/build/Products" OBJROOT="$PWD/build/Intermediates" \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets build
if [[ -n "${ROOMS_PROFILE:-}" && -n "${ROOMS_IDENTITY:-}" && -n "${ROOMS_DEVICE_UDID:-}" ]]; then
  python3 scripts/sign-development.py --app build/Products/Debug-iphoneos/ROOMS.app \
    --profile "$ROOMS_PROFILE" --identity "$ROOMS_IDENTITY" \
    --device "$ROOMS_DEVICE_UDID" --development-icon
else
  print 'Unsigned iPhone build only. Supply ROOMS_PROFILE, ROOMS_IDENTITY and ROOMS_DEVICE_UDID to sign for an authorized device.'
fi
