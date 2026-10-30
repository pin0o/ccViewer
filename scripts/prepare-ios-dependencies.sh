#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
brew install cmake pkg-config
(cd library && bash -e build.sh)
test -f library/install/lib/libssh.a
curl --fail --location --retry 3 https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.4_dynamic.zip -o /tmp/googlecast.zip
unzip -q /tmp/googlecast.zip

# The repository already ships an arm64 iOS FFmpeg archive. Generate the matching
# public headers rather than recompiling every codec on each CI cache miss.
lipo -verify_arch arm64 ffplayer/ffplayer/ffmpeg.a
git init work/ffmpeg
git -C work/ffmpeg remote add origin https://github.com/FFmpeg/FFmpeg.git
git -C work/ffmpeg fetch --depth 1 origin 3eb0cb3b0b0c4ad3ca14818adb26e0f2b6fa1c6c
git -C work/ffmpeg checkout --detach FETCH_HEAD
task_output="$PWD/work/output"
mkdir -p "$task_output"
(
  cd work/ffmpeg
  ./configure --cc="$(xcrun --sdk iphoneos -f clang)" \
    --enable-cross-compile --disable-debug --disable-programs --disable-doc --enable-pic \
    --prefix="$task_output" --target-os=darwin --arch=arm64 \
    --sysroot="$(xcrun --sdk iphoneos --show-sdk-path)" --disable-audiotoolbox \
    --extra-cflags='-mios-version-min=17.0' --extra-ldflags='-mios-version-min=17.0'
  make install-headers
)
cp ffplayer/ffplayer/ffmpeg.a "$task_output/ffmpeg.a"
test -f "$task_output/include/libavformat/avformat.h"
