#!/usr/bin/env bash
#
# Uploads the built IPA to TestFlight.
#
# Exists because the App Store Connect issuer ID is not discoverable from this
# machine — it is not in the keychain, not in Xcode's user data, and altool's own
# logs record the key path but never the issuer. Without somewhere to keep it, every
# release turns into a hunt for a UUID. It lives in ~/.appstoreconnect/issuer_id,
# next to the private keys altool already reads from that directory by convention.
#
# Deliberately not in the repo: the issuer is account-level and shared with the
# Superset app, so it belongs in $HOME, not in a checkout that gets pushed.
#
# The release workflow runs this too, after writing the same two files into the
# runner's $HOME from repository secrets. Keeping one implementation means the
# upload a human does and the upload CI does cannot drift apart.
#
#   tool/upload-testflight.sh [--build]
#
#     --build   run `flutter build ipa` first, instead of uploading whatever is
#               already sitting in build/ios/ipa
set -euo pipefail

# Gather Companion. Superset is Y8BLV9TS8M, same issuer. Overridable because CI
# supplies whichever key its secret holds.
KEY_ID="${ASC_KEY_ID:-9FVGFF4ZJ8}"
ISSUER_FILE="$HOME/.appstoreconnect/issuer_id"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
ipa="$root/build/ios/ipa/gather_companion.ipa"

if [ ! -f "$ISSUER_FILE" ]; then
  echo "No issuer ID at $ISSUER_FILE" >&2
  echo "Get it from App Store Connect → Users and Access → Integrations →" >&2
  echo "App Store Connect API; it sits above the key table. Then:" >&2
  echo "  printf '%s\\n' <issuer-uuid> > $ISSUER_FILE && chmod 600 $ISSUER_FILE" >&2
  exit 1
fi

# Exports through the committed options rather than the ones Flutter generates,
# so a build from this machine is packaged the same way a release from CI is.
if [ "${1:-}" = '--build' ]; then
  ( cd "$root" && flutter build ipa --export-options-plist ios/ExportOptions.plist )
fi

if [ ! -f "$ipa" ]; then
  echo "No IPA at $ipa — run with --build first." >&2
  exit 1
fi

# Read the build number out of the bundle rather than from pubspec.yaml: what is
# about to be uploaded is what is *in the IPA*, and those two disagree the moment
# someone bumps the version without rebuilding. App Store Connect rejects a
# duplicate build number, so it is worth seeing before the upload starts.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -q -o "$ipa" 'Payload/Runner.app/Info.plist' -d "$tmp"
plist="$tmp/Payload/Runner.app/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
build="$(plutil -extract CFBundleVersion raw "$plist")"

echo "uploading $version+$build  ($(du -h "$ipa" | cut -f1))"

xcrun altool --upload-app --type ios \
  -f "$ipa" \
  --apiKey "$KEY_ID" \
  --apiIssuer "$(cat "$ISSUER_FILE")"
