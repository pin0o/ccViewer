#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_output="$PWD/build/simulator-screenshots"
mkdir -p "$task_output"
xcodebuild -workspace CryptCloudViewer.xcworkspace -scheme CryptCloudViewer \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/build/simulator-derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS='' DEVELOPMENT_TEAM='' \
  build 2>&1 | tee "$task_output/xcodebuild.log"
task_app="$PWD/build/simulator-derived/Build/Products/Debug-iphonesimulator/CryptCloudViewer.app"
codesign --force --deep --sign - "$task_app"

xcrun simctl list devices available --json > "$task_output/devices.json"
task_udid="$(python3 - "$task_output/devices.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['devices']
options = [(runtime, device) for runtime, items in devices.items() if '.iOS-' in runtime
           for device in items if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not options:
    raise SystemExit('No available iPhone simulator runtime')
runtime, device = max(options, key=lambda item: (item[0], item[1]['name'] == 'iPhone 17 Pro', item[1]['name']))
print(device['udid'])
PY
)"
trap 'xcrun simctl shutdown "$task_udid" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$task_udid" || true
xcrun simctl bootstatus "$task_udid" -b
xcrun simctl ui "$task_udid" appearance light
xcrun simctl status_bar "$task_udid" override --time '9:41' --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$task_udid" "$task_app"
task_bundle=io.github.pin0o.ccViewerPoC
task_container="$(xcrun simctl get_app_container "$task_udid" "$task_bundle" data)"
xcrun swift scripts/make-simulator-fixtures.swift "$task_container/Documents"

for task_variant in list grid-small grid-medium grid-large; do
  task_layout=grid
  task_size="${task_variant#grid-}"
  if [[ "$task_variant" == list ]]; then task_layout=list; task_size=medium; fi
  xcrun simctl terminate "$task_udid" "$task_bundle" >/dev/null 2>&1 || true
  rm -f "$task_container/Library/Caches/.ui-snapshot-ready"
  xcrun simctl launch --console-pty "$task_udid" "$task_bundle" \
    --snapshot-local-files -tutorial YES -paramInit 1 -previousBuildNo 197 \
    -cloudPlaypos NO -cloudPlaylist NO -savePlaypos NO \
    -browser.layout "$task_layout" -browser.gridSize "$task_size" \
    -AppleLanguages '(ja)' -AppleLocale ja_JP \
    > "$task_output/$task_variant-console.log" 2>&1 &
  task_launch_pid=$!
  task_ready=no
  for task_attempt in {1..90}; do
    if [[ -f "$task_container/Library/Caches/.ui-snapshot-ready" ]] && \
       [[ "$(cat "$task_container/Library/Caches/.ui-snapshot-ready")" == "$task_layout:$task_size" ]]; then
      task_ready=yes
      break
    fi
    sleep 1
  done
  if [[ "$task_ready" != yes ]]; then
    xcrun simctl io "$task_udid" screenshot "$task_output/$task_variant-failed.png" || true
    tail -n 80 "$task_output/$task_variant-console.log"
    exit 1
  fi
  sleep 5
  xcrun simctl io "$task_udid" screenshot "$task_output/$task_variant.png"
  xcrun simctl terminate "$task_udid" "$task_bundle"
  wait "$task_launch_pid" || true
done
printf 'Screenshots: %s\n' "$task_output"
