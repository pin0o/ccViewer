#!/bin/bash
set -euo pipefail

# The IPA is intentionally unsigned: install/sign it with AltStore afterwards.
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  printf '%s\n' 'IPA builds require macOS and Xcode 26 or later.' >&2
  exit 2
fi

cd "$(dirname "$0")/.."
task_build_dir="${IPA_BUILD_DIR:-$PWD/build/ipa}"
mkdir -p "$task_build_dir"
task_build_dir="$(cd "$task_build_dir" && pwd)"

xcodebuild -resolvePackageDependencies -workspace CryptCloudViewer.xcworkspace -scheme CryptCloudViewer
xcodebuild archive \
  -workspace CryptCloudViewer.xcworkspace \
  -scheme CryptCloudViewer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$task_build_dir/CryptCloudViewer.xcarchive" \
  -derivedDataPath "$task_build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  | tee "$task_build_dir/xcodebuild.log"

task_app="$task_build_dir/CryptCloudViewer.xcarchive/Products/Applications/CryptCloudViewer.app"
test -d "$task_app"
# Fail before packaging if this experimental build retains upstream identities.
python3 - "$task_app" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
expected = {'': 'io.github.pin0o.ccViewerPoC',
            'RemoteCloud': 'io.github.pin0o.RemoteCloudPoC',
            'ffplayer': 'io.github.pin0o.ffplayerPoC',
            'ffconverter': 'io.github.pin0o.ffconverterPoC'}
for framework, identifier in expected.items():
    bundle = app / 'Frameworks' / (framework + '.framework') if framework else app
    with (bundle / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != identifier:
        raise SystemExit(f'Unexpected PoC identity in {bundle}: {info.get("CFBundleIdentifier")}')
    if not framework and info.get('CFBundleDisplayName') != 'CryptCloudViewer PoC':
        raise SystemExit('PoC display name is missing')
print('PoC app and framework identities verified')
PY
task_payload="$task_build_dir/package"
rm -rf "$task_payload"
mkdir -p "$task_payload/Payload"
ditto "$task_app" "$task_payload/Payload/CryptCloudViewer.app"
rm -f "$task_build_dir/CryptCloudViewerPoC-unsigned.ipa"
(cd "$task_payload" && /usr/bin/zip -qry "$task_build_dir/CryptCloudViewerPoC-unsigned.ipa" Payload)
unzip -tq "$task_build_dir/CryptCloudViewerPoC-unsigned.ipa"
printf 'Unsigned IPA: %s\n' "$task_build_dir/CryptCloudViewerPoC-unsigned.ipa"
