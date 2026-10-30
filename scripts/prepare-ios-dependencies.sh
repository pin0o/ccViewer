#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
brew install cmake pkg-config
if [[ ! -f library/install/lib/libssh.a ]]; then
  (cd library && bash -e build.sh)
fi
test -f library/install/lib/libssh.a
if [[ ! -d GoogleCastSDK-ios-4.8.4_dynamic_xcframework ]]; then
  curl --fail --location --retry 3 https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.4_dynamic.zip -o /tmp/googlecast.zip
  unzip -q /tmp/googlecast.zip
fi

# The checked-in archive targets iOS 26. Rebuild for the supported iOS 17 target.
git clone --depth 1 --branch v1.1.1 https://github.com/xqq/libaribcaption.git work/libaribcaption
git init work/ffmpeg
git -C work/ffmpeg remote add origin https://github.com/FFmpeg/FFmpeg.git
git -C work/ffmpeg fetch --depth 1 origin 3eb0cb3b0b0c4ad3ca14818adb26e0f2b6fa1c6c
git -C work/ffmpeg checkout --detach FETCH_HEAD
(
  cd work
  bash -e apply_patch.sh
  rm -rf build output
  bash -e build_libaribcaption.sh
  bash -e build_ffmpeg.sh
  libtool -static -o output/ffmpeg.a output/lib/*.a
)
test -f work/output/ffmpeg.a
lipo work/output/ffmpeg.a -verify_arch arm64
python3 - <<'PY'
import re, subprocess
text = subprocess.check_output(['xcrun', 'otool', '-l', 'work/output/ffmpeg.a'], text=True)
versions = []
for block in re.split(r'(?=Load command \d+)', text):
    if 'cmd LC_BUILD_VERSION' in block:
        match = re.search(r'\bminos\s+(\d+(?:\.\d+)*)', block)
    elif 'cmd LC_VERSION_MIN_IPHONEOS' in block:
        match = re.search(r'\bversion\s+(\d+(?:\.\d+)*)', block)
    else:
        continue
    if match:
        version = tuple(map(int, match.group(1).split('.')))
        versions.append(version + (0,) * (3 - len(version)))
if not versions or max(versions) > (17, 6, 0):
    raise SystemExit(f'FFmpeg deployment target exceeds iOS 17.6: {max(versions) if versions else "unknown"}')
print('FFmpeg maximum object deployment target:', '.'.join(map(str, max(versions))))
PY
