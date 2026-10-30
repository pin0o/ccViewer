#include "player_main.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/display.h>
#include <libswscale/swscale.h>
}

namespace {
struct Input {
    void *opaque;
    int (*read)(void *, unsigned char *, int);
    long long (*seek)(void *, long long, int);
    int (*interrupted)(void *);
};
int readInput(void *p, uint8_t *buffer, int size) {
    auto &input = *static_cast<Input *>(p);
    return input.interrupted(input.opaque) ? AVERROR_EXIT : input.read(input.opaque, buffer, size);
}
int64_t seekInput(void *p, int64_t offset, int whence) {
    auto &input = *static_cast<Input *>(p);
    return input.interrupted(input.opaque) ? AVERROR_EXIT : input.seek(input.opaque, offset, whence);
}
int interruptInput(void *p) {
    auto &input = *static_cast<Input *>(p);
    return input.interrupted(input.opaque);
}
struct Resources {
    AVFormatContext *format = nullptr;
    AVIOContext *io = nullptr;
    AVCodecContext *codec = nullptr;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    SwsContext *scaler = nullptr;
    ~Resources() {
        sws_freeContext(scaler);
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&codec);
        avformat_close_input(&format);
        if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    }
};
}

extern "C" int thumbnail_extract(void *opaque,
    int (*read_packet)(void *, unsigned char *, int),
    long long (*seek)(void *, long long, int), int (*interrupted)(void *), int maximum_pixels,
    unsigned char **rgba, int *width, int *height, double *rotation) {
    if (!rgba || !width || !height || !rotation || !read_packet || !seek || !interrupted || maximum_pixels < 1 || maximum_pixels > 512)
        return AVERROR(EINVAL);
    *rgba = nullptr;
    Input input {opaque, read_packet, seek, interrupted};
    Resources r;
    r.format = avformat_alloc_context();
    if (!r.format || !r.packet || !r.frame) return AVERROR(ENOMEM);
    auto *buffer = static_cast<uint8_t *>(av_malloc(32 * 1024));
    if (!buffer) return AVERROR(ENOMEM);
    r.io = avio_alloc_context(buffer, 32 * 1024, 0, &input, readInput, nullptr, seekInput);
    if (!r.io) { av_free(buffer); return AVERROR(ENOMEM); }
    r.format->pb = r.io;
    r.format->flags |= AVFMT_FLAG_CUSTOM_IO;
    r.format->interrupt_callback = {interruptInput, &input};
    r.format->probesize = 2 * 1024 * 1024;
    r.format->max_analyze_duration = 2 * AV_TIME_BASE;
    if (avformat_open_input(&r.format, nullptr, nullptr, nullptr) < 0 ||
        avformat_find_stream_info(r.format, nullptr) < 0) return AVERROR_INVALIDDATA;
    int index = av_find_best_stream(r.format, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (index < 0) return index;
    auto *stream = r.format->streams[index];
    const auto *decoder = avcodec_find_decoder(stream->codecpar->codec_id);
    r.codec = avcodec_alloc_context3(decoder);
    if (!decoder || !r.codec || avcodec_parameters_to_context(r.codec, stream->codecpar) < 0) return AVERROR_INVALIDDATA;
    // Refuse decompression bombs; a thumbnail must not allocate an arbitrary source frame.
    if (r.codec->width <= 0 || r.codec->height <= 0 ||
        int64_t(r.codec->width) * r.codec->height > 64LL * 1024 * 1024) return AVERROR_INVALIDDATA;
    r.codec->thread_count = 1;
    r.codec->max_pixels = 64LL * 1024 * 1024;
    if (avcodec_open2(r.codec, decoder, nullptr) < 0) return AVERROR_INVALIDDATA;
    *rotation = 0;
#if LIBAVFORMAT_VERSION_MAJOR >= 61
    const auto *side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (side && side->size >= 9 * sizeof(int32_t))
        *rotation = -av_display_rotation_get(reinterpret_cast<const int32_t *>(side->data));
#else
    size_t sideSize = 0;
    const auto *side = av_stream_get_side_data(stream, AV_PKT_DATA_DISPLAYMATRIX, &sideSize);
    if (side && sideSize >= 9 * sizeof(int32_t))
        *rotation = -av_display_rotation_get(reinterpret_cast<const int32_t *>(side));
#endif
    // Prefer a nearby keyframe, but an unseekable file can still yield its first frame.
    if (stream->duration > 0 && av_q2d(stream->time_base) * stream->duration > 1)
        av_seek_frame(r.format, index, int64_t(1.0 / av_q2d(stream->time_base)), AVSEEK_FLAG_BACKWARD);
    bool draining = false;
    for (int packets = 0; packets < 4096 && !interrupted(opaque); ++packets) {
        int receive = avcodec_receive_frame(r.codec, r.frame);
        if (receive == 0) {
            if (r.frame->width <= 0 || r.frame->height <= 0) return AVERROR_INVALIDDATA;
            double scale = std::min(1.0, double(maximum_pixels) / std::max(r.frame->width, r.frame->height));
            *width = std::max(1, int(r.frame->width * scale));
            *height = std::max(1, int(r.frame->height * scale));
            auto *pixels = static_cast<uint8_t *>(std::malloc(*width * *height * 4));
            if (!pixels) return AVERROR(ENOMEM);
            r.scaler = sws_getContext(r.frame->width, r.frame->height, AVPixelFormat(r.frame->format),
                *width, *height, AV_PIX_FMT_RGBA, SWS_BILINEAR, nullptr, nullptr, nullptr);
            if (!r.scaler) { std::free(pixels); return AVERROR_INVALIDDATA; }
            uint8_t *planes[] = {pixels}; int strides[] = {*width * 4};
            int rows = sws_scale(r.scaler, r.frame->data, r.frame->linesize, 0, r.frame->height, planes, strides);
            if (rows != *height) { std::free(pixels); return AVERROR_INVALIDDATA; }
            *rgba = pixels;
            return 0;
        }
        if (receive != AVERROR(EAGAIN) || draining) break;
        int status = av_read_frame(r.format, r.packet);
        if (status < 0) { draining = true; avcodec_send_packet(r.codec, nullptr); continue; }
        if (r.packet->stream_index == index) avcodec_send_packet(r.codec, r.packet);
        av_packet_unref(r.packet);
    }
    return interrupted(opaque) ? AVERROR_EXIT : AVERROR_INVALIDDATA;
}

extern "C" void thumbnail_free(unsigned char *rgba) { std::free(rgba); }
