// Native regression test for the independent decoder (no UIKit or playback engine).
// Pass a fixture directory containing sample.mp4, sample.mkv, sample.ts,
// rotated.mp4, audio.wav and broken.bin. Generate fixtures with the ffmpeg CLI.
#include "player_main.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <string>
extern "C" {
#include <libavutil/error.h>
}

struct Input {
    FILE *file;
    bool cancel;
    size_t bytes = 0;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
};
static int readBytes(void *opaque, unsigned char *buffer, int length) {
    auto &input = *static_cast<Input *>(opaque);
    auto count = std::fread(buffer, 1, length, input.file);
    input.bytes += count;
    return count ? int(count) : AVERROR_EOF;
}
static long long seekBytes(void *opaque, long long offset, int whence) {
    auto &input = *static_cast<Input *>(opaque);
    if (whence & 0x10000) {
        auto position = std::ftell(input.file);
        std::fseek(input.file, 0, SEEK_END);
        auto size = std::ftell(input.file);
        std::fseek(input.file, position, SEEK_SET);
        return size;
    }
    return std::fseek(input.file, offset, whence & ~0x20000) == 0 ? std::ftell(input.file) : -1;
}
static int interrupted(void *opaque) {
    auto &input = *static_cast<Input *>(opaque);
    return input.cancel || input.bytes > 16 * 1024 * 1024 ||
        std::chrono::steady_clock::now() - input.start > std::chrono::seconds(5);
}
static void test(const std::string &path, bool expected, bool cancel = false, bool rotated = false) {
    Input input {std::fopen(path.c_str(), "rb"), cancel};
    assert(input.file);
    unsigned char *pixels = nullptr;
    int width = 0, height = 0;
    double rotation = 0;
    int result = thumbnail_extract(&input, readBytes, seekBytes, interrupted, 144, &pixels, &width, &height, &rotation);
    assert((result == 0) == expected);
    if (expected) {
        assert(pixels && width > 0 && width <= 144 && height > 0 && height <= 144);
        bool content = false;
        for (int i = 0; i < width * height * 4; ++i) content |= pixels[i] != 0;
        assert(content);
        if (rotated) assert(std::abs(std::abs(rotation) - 90) < 0.1);
    } else { assert(pixels == nullptr); }
    thumbnail_free(pixels);
    std::fclose(input.file);
    std::printf("PASS %s%s\n", path.c_str(), cancel ? " (cancelled)" : "");
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::string base = argv[1];
    for (const auto *name : {"sample.mp4", "sample.mkv", "sample.ts"}) test(base + "/" + name, true);
    test(base + "/rotated.mp4", true, false, true);
    test(base + "/audio.wav", false);
    test(base + "/broken.bin", false);
    test(base + "/sample.mp4", false, true);
}
