#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_root="$PWD"
task_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
task_jobs="$(getconf _NPROCESSORS_ONLN)"
brew install cmake pkg-config

# Simulator and device archives use different cache keys and separate CI jobs.
rm -rf library/install build/simulator-native work/build work/output
mkdir -p library/install build/simulator-native
(
  cd library/openssl
  ./Configure iossimulator-arm64-xcrun no-shared no-tests no-legacy \
    --prefix="$task_root/library/install" --libdir=lib -mios-simulator-version-min=17.0
  make -j"$task_jobs"
  make install_sw
)
cmake -S library/libssh -B build/simulator-native/libssh \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$task_sdk" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$task_root/library/install" \
  -DCMAKE_PREFIX_PATH="$task_root/library/install" -DOPENSSL_ROOT_DIR="$task_root/library/install" \
  -DOPENSSL_INCLUDE_DIR="$task_root/library/install/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$task_root/library/install/lib/libcrypto.a" \
  -DOPENSSL_SSL_LIBRARY="$task_root/library/install/lib/libssl.a" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DBUILD_STATIC_LIB=OFF -DBUILD_SHARED_LIBS=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTING=OFF -DWITH_GSSAPI=OFF
cmake --build build/simulator-native/libssh --parallel "$task_jobs"
cmake --install build/simulator-native/libssh

if [[ ! -d GoogleCastSDK-ios-4.8.4_dynamic_xcframework ]]; then
  curl --fail --location --retry 3 https://dl.google.com/dl/chromecast/sdk/ios/GoogleCastSDK-ios-4.8.4_dynamic.zip -o build/simulator-native/googlecast.zip
  unzip -q build/simulator-native/googlecast.zip
fi
git clone --depth 1 --branch v1.1.1 https://github.com/xqq/libaribcaption.git work/libaribcaption
git init work/ffmpeg
git -C work/ffmpeg remote add origin https://github.com/FFmpeg/FFmpeg.git
git -C work/ffmpeg fetch --depth 1 origin 3eb0cb3b0b0c4ad3ca14818adb26e0f2b6fa1c6c
git -C work/ffmpeg checkout --detach FETCH_HEAD
(cd work && bash -e apply_patch.sh)
cmake -S work/libaribcaption -B work/build/libaribcaption \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$task_sdk" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$task_root/work/output"
cmake --build work/build/libaribcaption --parallel "$task_jobs"
cmake --install work/build/libaribcaption
(
  mkdir -p work/build/ffmpeg
  cd work/build/ffmpeg
  export PKG_CONFIG_PATH="$task_root/work/output/lib/pkgconfig"
  ../../ffmpeg/configure \
    --cc="$(xcrun --sdk iphonesimulator -f clang)" \
    --enable-cross-compile --disable-debug --disable-programs --disable-doc --enable-pic \
    --prefix="$task_root/work/output" --target-os=darwin --arch=arm64 \
    --sysroot="$task_sdk" --disable-audiotoolbox --enable-libaribcaption \
    --extra-cflags="-target arm64-apple-ios17.0-simulator" \
    --extra-ldflags="-target arm64-apple-ios17.0-simulator"
  make -j"$task_jobs" install
)
libtool -static -o work/output/ffmpeg.a work/output/lib/*.a
python3 - <<'PY'
import re, subprocess
for path in ['library/install/lib/libcrypto.a', 'library/install/lib/libssl.a',
             'library/install/lib/libssh.a', 'work/output/ffmpeg.a']:
    subprocess.run(['lipo', path, '-verify_arch', 'arm64'], check=True)
    text = subprocess.check_output(['xcrun', 'otool', '-l', path], text=True)
    platforms = set(re.findall(r'\bplatform\s+(\w+)', text))
    if not platforms or platforms - {'7', 'IOSSIMULATOR'}:
        raise SystemExit(f'Expected iOS Simulator objects in {path}, found {platforms}')
    print('Verified arm64 iOS Simulator archive:', path)
PY
