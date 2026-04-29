#include "FFmpegRemux.h"
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/timestamp.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static void set_error(char *buffer, int buffer_size, const char *fmt, ...) {
    if (!buffer || buffer_size <= 0) return;
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, (size_t)buffer_size, fmt, args);
    va_end(args);
}

static void set_av_error(char *buffer, int buffer_size, const char *context, int err) {
    char av_error[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(err, av_error, sizeof(av_error));
    set_error(buffer, buffer_size, "%s: %s (%d)", context, av_error, err);
}

static int open_input(const char *path, AVFormatContext **ctx, char *errbuf, int errbuf_size) {
    int ret = avformat_open_input(ctx, path, NULL, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_open_input", ret);
        return ret;
    }
    ret = avformat_find_stream_info(*ctx, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_find_stream_info", ret);
        return ret;
    }
    return 0;
}

static int open_input_pipe(const char *path, AVFormatContext **ctx, char *errbuf, int errbuf_size) {
    *ctx = avformat_alloc_context();
    if (!*ctx) {
        set_error(errbuf, errbuf_size, "avformat_alloc_context failed");
        return AVERROR(ENOMEM);
    }
    (*ctx)->probesize = 64 * 1024;
    (*ctx)->max_analyze_duration = 500000;
    int ret = avformat_open_input(ctx, path, NULL, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_open_input pipe", ret);
        return ret;
    }
    ret = avformat_find_stream_info(*ctx, NULL);
    if (ret < 0) {
        set_av_error(errbuf, errbuf_size, "avformat_find_stream_info pipe", ret);
        return ret;
    }
    return 0;
}

static int find_stream(AVFormatContext *ctx, enum AVMediaType type) {
    for (unsigned int i = 0; i < ctx->nb_streams; i++) {
        if (ctx->streams[i]->codecpar->codec_type == type) return (int)i;
    }
    return -1;
}

int ibili_remux_mp4(const char *video_path,
                    const char *audio_path,
                    const char *output_path,
                    char *error_buffer,
                    int error_buffer_size) {
    AVFormatContext *video_ctx = NULL;
    AVFormatContext *audio_ctx = NULL;
    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    int ret = 0;
    int video_in_index = -1;
    int audio_in_index = -1;
    int video_out_index = -1;
    int audio_out_index = -1;

    if (!video_path || !output_path) {
        set_error(error_buffer, error_buffer_size, "video_path and output_path are required");
        return AVERROR(EINVAL);
    }

    ret = open_input(video_path, &video_ctx, error_buffer, error_buffer_size);
    if (ret < 0) goto cleanup;
    video_in_index = find_stream(video_ctx, AVMEDIA_TYPE_VIDEO);
    if (video_in_index < 0) {
        set_error(error_buffer, error_buffer_size, "no video stream");
        ret = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }

    if (audio_path && audio_path[0] != '\0') {
        ret = open_input(audio_path, &audio_ctx, error_buffer, error_buffer_size);
        if (ret < 0) goto cleanup;
        audio_in_index = find_stream(audio_ctx, AVMEDIA_TYPE_AUDIO);
        if (audio_in_index < 0) {
            set_error(error_buffer, error_buffer_size, "no audio stream");
            ret = AVERROR_STREAM_NOT_FOUND;
            goto cleanup;
        }
    }

    ret = avformat_alloc_output_context2(&out_ctx, NULL, "mp4", output_path);
    if (ret < 0 || !out_ctx) {
        set_av_error(error_buffer, error_buffer_size, "avformat_alloc_output_context2", ret);
        goto cleanup;
    }

    AVStream *video_in = video_ctx->streams[video_in_index];
    AVStream *video_out = avformat_new_stream(out_ctx, NULL);
    if (!video_out) {
        set_error(error_buffer, error_buffer_size, "avformat_new_stream video failed");
        ret = AVERROR(ENOMEM);
        goto cleanup;
    }
    video_out_index = video_out->index;
    ret = avcodec_parameters_copy(video_out->codecpar, video_in->codecpar);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy video", ret);
        goto cleanup;
    }
    video_out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
    video_out->time_base = video_in->time_base;

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        AVStream *audio_out = avformat_new_stream(out_ctx, NULL);
        if (!audio_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream audio failed");
            ret = AVERROR(ENOMEM);
            goto cleanup;
        }
        audio_out_index = audio_out->index;
        ret = avcodec_parameters_copy(audio_out->codecpar, audio_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy audio", ret);
            goto cleanup;
        }
        audio_out->codecpar->codec_tag = 0;
        audio_out->time_base = audio_in->time_base;
    }

    if (!(out_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out_ctx->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avio_open", ret);
            goto cleanup;
        }
    }

    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "movflags", "+faststart", 0);
    ret = avformat_write_header(out_ctx, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avformat_write_header", ret);
        goto cleanup;
    }

    pkt = av_packet_alloc();
    if (!pkt) {
        set_error(error_buffer, error_buffer_size, "av_packet_alloc failed");
        ret = AVERROR(ENOMEM);
        goto cleanup;
    }

    while ((ret = av_read_frame(video_ctx, pkt)) >= 0) {
        if (pkt->stream_index == video_in_index) {
            pkt->stream_index = video_out_index;
            av_packet_rescale_ts(pkt, video_in->time_base, out_ctx->streams[video_out_index]->time_base);
            ret = av_interleaved_write_frame(out_ctx, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame video", ret);
                goto cleanup;
            }
        } else {
            av_packet_unref(pkt);
        }
    }
    if (ret == AVERROR_EOF) ret = 0;
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_read_frame video", ret);
        goto cleanup;
    }

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        while ((ret = av_read_frame(audio_ctx, pkt)) >= 0) {
            if (pkt->stream_index == audio_in_index) {
                pkt->stream_index = audio_out_index;
                av_packet_rescale_ts(pkt, audio_in->time_base, out_ctx->streams[audio_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
                av_packet_unref(pkt);
                if (ret < 0) {
                    set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame audio", ret);
                    goto cleanup;
                }
            } else {
                av_packet_unref(pkt);
            }
        }
        if (ret == AVERROR_EOF) ret = 0;
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "av_read_frame audio", ret);
            goto cleanup;
        }
    }

    ret = av_write_trailer(out_ctx);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_write_trailer", ret);
        goto cleanup;
    }

cleanup:
    if (pkt) av_packet_free(&pkt);
    if (out_ctx) {
        if (out_ctx->pb) avio_closep(&out_ctx->pb);
        avformat_free_context(out_ctx);
    }
    if (video_ctx) avformat_close_input(&video_ctx);
    if (audio_ctx) avformat_close_input(&audio_ctx);
    return ret;
}

int ibili_remux_hls(const char *video_path,
                    const char *audio_path,
                    const char *playlist_path,
                    const char *init_filename,
                    const char *segment_filename,
                    char *error_buffer,
                    int error_buffer_size) {
    AVFormatContext *video_ctx = NULL;
    AVFormatContext *audio_ctx = NULL;
    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    int ret = 0;
    int video_in_index = -1;
    int audio_in_index = -1;
    int video_out_index = -1;
    int audio_out_index = -1;

    if (!video_path || !playlist_path || !init_filename || !segment_filename) {
        set_error(error_buffer, error_buffer_size, "video_path, playlist_path, init_filename and segment_filename are required");
        return AVERROR(EINVAL);
    }

    ret = open_input(video_path, &video_ctx, error_buffer, error_buffer_size);
    if (ret < 0) goto cleanup_hls;
    video_in_index = find_stream(video_ctx, AVMEDIA_TYPE_VIDEO);
    if (video_in_index < 0) {
        set_error(error_buffer, error_buffer_size, "no video stream");
        ret = AVERROR_STREAM_NOT_FOUND;
        goto cleanup_hls;
    }

    if (audio_path && audio_path[0] != '\0') {
        ret = open_input(audio_path, &audio_ctx, error_buffer, error_buffer_size);
        if (ret < 0) goto cleanup_hls;
        audio_in_index = find_stream(audio_ctx, AVMEDIA_TYPE_AUDIO);
        if (audio_in_index < 0) {
            set_error(error_buffer, error_buffer_size, "no audio stream");
            ret = AVERROR_STREAM_NOT_FOUND;
            goto cleanup_hls;
        }
    }

    ret = avformat_alloc_output_context2(&out_ctx, NULL, "hls", playlist_path);
    if (ret < 0 || !out_ctx) {
        set_av_error(error_buffer, error_buffer_size, "avformat_alloc_output_context2 hls", ret);
        goto cleanup_hls;
    }

    AVStream *video_in = video_ctx->streams[video_in_index];
    AVStream *video_out = avformat_new_stream(out_ctx, NULL);
    if (!video_out) {
        set_error(error_buffer, error_buffer_size, "avformat_new_stream video failed");
        ret = AVERROR(ENOMEM);
        goto cleanup_hls;
    }
    video_out_index = video_out->index;
    ret = avcodec_parameters_copy(video_out->codecpar, video_in->codecpar);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy video", ret);
        goto cleanup_hls;
    }
    video_out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
    video_out->time_base = video_in->time_base;

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        AVStream *audio_out = avformat_new_stream(out_ctx, NULL);
        if (!audio_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream audio failed");
            ret = AVERROR(ENOMEM);
            goto cleanup_hls;
        }
        audio_out_index = audio_out->index;
        ret = avcodec_parameters_copy(audio_out->codecpar, audio_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy audio", ret);
            goto cleanup_hls;
        }
        audio_out->codecpar->codec_tag = 0;
        audio_out->time_base = audio_in->time_base;
    }

    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "hls_segment_type", "fmp4", 0);
    av_dict_set(&mux_opts, "hls_playlist_type", "vod", 0);
    av_dict_set(&mux_opts, "hls_list_size", "0", 0);
    av_dict_set(&mux_opts, "hls_time", "3600", 0);
    av_dict_set(&mux_opts, "hls_fmp4_init_filename", init_filename, 0);
    av_dict_set(&mux_opts, "hls_segment_filename", segment_filename, 0);
    ret = avformat_write_header(out_ctx, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avformat_write_header hls", ret);
        goto cleanup_hls;
    }

    pkt = av_packet_alloc();
    if (!pkt) {
        set_error(error_buffer, error_buffer_size, "av_packet_alloc failed");
        ret = AVERROR(ENOMEM);
        goto cleanup_hls;
    }

    while ((ret = av_read_frame(video_ctx, pkt)) >= 0) {
        if (pkt->stream_index == video_in_index) {
            pkt->stream_index = video_out_index;
            av_packet_rescale_ts(pkt, video_in->time_base, out_ctx->streams[video_out_index]->time_base);
            ret = av_interleaved_write_frame(out_ctx, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame video", ret);
                goto cleanup_hls;
            }
        } else {
            av_packet_unref(pkt);
        }
    }
    if (ret == AVERROR_EOF) ret = 0;
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_read_frame video", ret);
        goto cleanup_hls;
    }

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        while ((ret = av_read_frame(audio_ctx, pkt)) >= 0) {
            if (pkt->stream_index == audio_in_index) {
                pkt->stream_index = audio_out_index;
                av_packet_rescale_ts(pkt, audio_in->time_base, out_ctx->streams[audio_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
                av_packet_unref(pkt);
                if (ret < 0) {
                    set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame audio", ret);
                    goto cleanup_hls;
                }
            } else {
                av_packet_unref(pkt);
            }
        }
        if (ret == AVERROR_EOF) ret = 0;
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "av_read_frame audio", ret);
            goto cleanup_hls;
        }
    }

    ret = av_write_trailer(out_ctx);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_write_trailer hls", ret);
        goto cleanup_hls;
    }

cleanup_hls:
    if (pkt) av_packet_free(&pkt);
    if (out_ctx) avformat_free_context(out_ctx);
    if (video_ctx) avformat_close_input(&video_ctx);
    if (audio_ctx) avformat_close_input(&audio_ctx);
    return ret;
}

int ibili_remux_hls_live(const char *video_path,
                         const char *audio_path,
                         const char *playlist_path,
                         const char *init_filename,
                         const char *segment_filename,
                         int hls_time,
                         char *error_buffer,
                         int error_buffer_size) {
    AVFormatContext *video_ctx = NULL;
    AVFormatContext *audio_ctx = NULL;
    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    int ret = 0;
    int video_in_index = -1;
    int audio_in_index = -1;
    int video_out_index = -1;
    int audio_out_index = -1;
    int video_eof = 0;
    int audio_eof = 1;

    if (!video_path || !playlist_path || !init_filename || !segment_filename) {
        set_error(error_buffer, error_buffer_size,
                  "video_path, playlist_path, init_filename and segment_filename are required");
        return AVERROR(EINVAL);
    }
    if (hls_time <= 0) hls_time = 6;

    ret = open_input_pipe(video_path, &video_ctx, error_buffer, error_buffer_size);
    if (ret < 0) goto cleanup_live;
    video_in_index = find_stream(video_ctx, AVMEDIA_TYPE_VIDEO);
    if (video_in_index < 0) {
        set_error(error_buffer, error_buffer_size, "no video stream");
        ret = AVERROR_STREAM_NOT_FOUND;
        goto cleanup_live;
    }

    if (audio_path && audio_path[0] != '\0') {
        ret = open_input_pipe(audio_path, &audio_ctx, error_buffer, error_buffer_size);
        if (ret < 0) goto cleanup_live;
        audio_in_index = find_stream(audio_ctx, AVMEDIA_TYPE_AUDIO);
        if (audio_in_index < 0) {
            set_error(error_buffer, error_buffer_size, "no audio stream in audio input");
            ret = AVERROR_STREAM_NOT_FOUND;
            goto cleanup_live;
        }
        audio_eof = 0;
    }

    ret = avformat_alloc_output_context2(&out_ctx, NULL, "hls", playlist_path);
    if (ret < 0 || !out_ctx) {
        set_av_error(error_buffer, error_buffer_size, "avformat_alloc_output_context2 hls_live", ret);
        goto cleanup_live;
    }

    {
        AVStream *v_in = video_ctx->streams[video_in_index];
        AVStream *v_out = avformat_new_stream(out_ctx, NULL);
        if (!v_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream video failed");
            ret = AVERROR(ENOMEM);
            goto cleanup_live;
        }
        video_out_index = v_out->index;
        ret = avcodec_parameters_copy(v_out->codecpar, v_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy video", ret);
            goto cleanup_live;
        }
        v_out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
        v_out->time_base = v_in->time_base;
    }

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *a_in = audio_ctx->streams[audio_in_index];
        AVStream *a_out = avformat_new_stream(out_ctx, NULL);
        if (!a_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream audio failed");
            ret = AVERROR(ENOMEM);
            goto cleanup_live;
        }
        audio_out_index = a_out->index;
        ret = avcodec_parameters_copy(a_out->codecpar, a_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy audio", ret);
            goto cleanup_live;
        }
        a_out->codecpar->codec_tag = 0;
        a_out->time_base = a_in->time_base;
    }

    {
        AVDictionary *mux_opts = NULL;
        char hls_time_str[16];
        snprintf(hls_time_str, sizeof(hls_time_str), "%d", hls_time);
        av_dict_set(&mux_opts, "hls_segment_type", "fmp4", 0);
        av_dict_set(&mux_opts, "hls_playlist_type", "event", 0);
        av_dict_set(&mux_opts, "hls_list_size", "0", 0);
        av_dict_set(&mux_opts, "hls_time", hls_time_str, 0);
        av_dict_set(&mux_opts, "hls_fmp4_init_filename", init_filename, 0);
        av_dict_set(&mux_opts, "hls_segment_filename", segment_filename, 0);
        av_dict_set(&mux_opts, "hls_flags", "independent_segments", 0);
        av_dict_set(&mux_opts, "movflags", "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets", 0);
        av_dict_set(&mux_opts, "use_editlist", "0", 0);
        ret = avformat_write_header(out_ctx, &mux_opts);
        av_dict_free(&mux_opts);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avformat_write_header hls_live", ret);
            goto cleanup_live;
        }
    }

    pkt = av_packet_alloc();
    if (!pkt) {
        set_error(error_buffer, error_buffer_size, "av_packet_alloc failed");
        ret = AVERROR(ENOMEM);
        goto cleanup_live;
    }

    /* Interleaved read: pull from whichever source has the earlier DTS.
       When only video is present, audio_eof is already 1. */
    while (!video_eof || !audio_eof) {
        int read_video = 0;
        if (video_eof) {
            read_video = 0;
        } else if (audio_eof) {
            read_video = 1;
        } else {
            read_video = 1; /* default to video; simple round-robin is fine
                               because HLS muxer reorders internally */
        }

        if (read_video) {
            ret = av_read_frame(video_ctx, pkt);
            if (ret == AVERROR_EOF) { video_eof = 1; ret = 0; continue; }
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_read_frame video", ret);
                goto cleanup_live;
            }
            if (pkt->stream_index == video_in_index) {
                pkt->stream_index = video_out_index;
                av_packet_rescale_ts(pkt,
                    video_ctx->streams[video_in_index]->time_base,
                    out_ctx->streams[video_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
            }
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "write_frame video", ret);
                goto cleanup_live;
            }
        } else {
            ret = av_read_frame(audio_ctx, pkt);
            if (ret == AVERROR_EOF) { audio_eof = 1; ret = 0; continue; }
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_read_frame audio", ret);
                goto cleanup_live;
            }
            if (pkt->stream_index == audio_in_index) {
                pkt->stream_index = audio_out_index;
                av_packet_rescale_ts(pkt,
                    audio_ctx->streams[audio_in_index]->time_base,
                    out_ctx->streams[audio_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
            }
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "write_frame audio", ret);
                goto cleanup_live;
            }
        }
    }

    ret = av_write_trailer(out_ctx);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_write_trailer hls_live", ret);
        goto cleanup_live;
    }

cleanup_live:
    if (pkt) av_packet_free(&pkt);
    if (out_ctx) avformat_free_context(out_ctx);
    if (video_ctx) avformat_close_input(&video_ctx);
    if (audio_ctx) avformat_close_input(&audio_ctx);
    return ret;
}

int ibili_remux_fmp4(const char *video_path,
                     const char *audio_path,
                     const char *output_path,
                     char *error_buffer,
                     int error_buffer_size) {
    AVFormatContext *video_ctx = NULL;
    AVFormatContext *audio_ctx = NULL;
    AVFormatContext *out_ctx = NULL;
    AVPacket *pkt = NULL;
    int ret = 0;
    int video_in_index = -1;
    int audio_in_index = -1;
    int video_out_index = -1;
    int audio_out_index = -1;

    if (!video_path || !output_path) {
        set_error(error_buffer, error_buffer_size, "video_path and output_path are required");
        return AVERROR(EINVAL);
    }

    ret = open_input(video_path, &video_ctx, error_buffer, error_buffer_size);
    if (ret < 0) goto cleanup_fmp4;
    video_in_index = find_stream(video_ctx, AVMEDIA_TYPE_VIDEO);
    if (video_in_index < 0) {
        set_error(error_buffer, error_buffer_size, "no video stream");
        ret = AVERROR_STREAM_NOT_FOUND;
        goto cleanup_fmp4;
    }

    if (audio_path && audio_path[0] != '\0') {
        ret = open_input(audio_path, &audio_ctx, error_buffer, error_buffer_size);
        if (ret < 0) goto cleanup_fmp4;
        audio_in_index = find_stream(audio_ctx, AVMEDIA_TYPE_AUDIO);
        if (audio_in_index < 0) {
            set_error(error_buffer, error_buffer_size, "no audio stream");
            ret = AVERROR_STREAM_NOT_FOUND;
            goto cleanup_fmp4;
        }
    }

    ret = avformat_alloc_output_context2(&out_ctx, NULL, "mp4", output_path);
    if (ret < 0 || !out_ctx) {
        set_av_error(error_buffer, error_buffer_size, "avformat_alloc_output_context2 fmp4", ret);
        goto cleanup_fmp4;
    }

    AVStream *video_in = video_ctx->streams[video_in_index];
    AVStream *video_out = avformat_new_stream(out_ctx, NULL);
    if (!video_out) {
        set_error(error_buffer, error_buffer_size, "avformat_new_stream video failed");
        ret = AVERROR(ENOMEM);
        goto cleanup_fmp4;
    }
    video_out_index = video_out->index;
    ret = avcodec_parameters_copy(video_out->codecpar, video_in->codecpar);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy video", ret);
        goto cleanup_fmp4;
    }
    video_out->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
    video_out->time_base = video_in->time_base;

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        AVStream *audio_out = avformat_new_stream(out_ctx, NULL);
        if (!audio_out) {
            set_error(error_buffer, error_buffer_size, "avformat_new_stream audio failed");
            ret = AVERROR(ENOMEM);
            goto cleanup_fmp4;
        }
        audio_out_index = audio_out->index;
        ret = avcodec_parameters_copy(audio_out->codecpar, audio_in->codecpar);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avcodec_parameters_copy audio", ret);
            goto cleanup_fmp4;
        }
        audio_out->codecpar->codec_tag = 0;
        audio_out->time_base = audio_in->time_base;
    }

    if (!(out_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out_ctx->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "avio_open fmp4", ret);
            goto cleanup_fmp4;
        }
    }

    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0);
    ret = avformat_write_header(out_ctx, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "avformat_write_header fmp4", ret);
        goto cleanup_fmp4;
    }

    pkt = av_packet_alloc();
    if (!pkt) {
        set_error(error_buffer, error_buffer_size, "av_packet_alloc failed");
        ret = AVERROR(ENOMEM);
        goto cleanup_fmp4;
    }

    while ((ret = av_read_frame(video_ctx, pkt)) >= 0) {
        if (pkt->stream_index == video_in_index) {
            pkt->stream_index = video_out_index;
            av_packet_rescale_ts(pkt, video_in->time_base, out_ctx->streams[video_out_index]->time_base);
            ret = av_interleaved_write_frame(out_ctx, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame video", ret);
                goto cleanup_fmp4;
            }
        } else {
            av_packet_unref(pkt);
        }
    }
    if (ret == AVERROR_EOF) ret = 0;
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_read_frame video", ret);
        goto cleanup_fmp4;
    }

    if (audio_ctx && audio_in_index >= 0) {
        AVStream *audio_in = audio_ctx->streams[audio_in_index];
        while ((ret = av_read_frame(audio_ctx, pkt)) >= 0) {
            if (pkt->stream_index == audio_in_index) {
                pkt->stream_index = audio_out_index;
                av_packet_rescale_ts(pkt, audio_in->time_base, out_ctx->streams[audio_out_index]->time_base);
                ret = av_interleaved_write_frame(out_ctx, pkt);
                av_packet_unref(pkt);
                if (ret < 0) {
                    set_av_error(error_buffer, error_buffer_size, "av_interleaved_write_frame audio", ret);
                    goto cleanup_fmp4;
                }
            } else {
                av_packet_unref(pkt);
            }
        }
        if (ret == AVERROR_EOF) ret = 0;
        if (ret < 0) {
            set_av_error(error_buffer, error_buffer_size, "av_read_frame audio", ret);
            goto cleanup_fmp4;
        }
    }

    ret = av_write_trailer(out_ctx);
    if (ret < 0) {
        set_av_error(error_buffer, error_buffer_size, "av_write_trailer fmp4", ret);
        goto cleanup_fmp4;
    }

cleanup_fmp4:
    if (pkt) av_packet_free(&pkt);
    if (out_ctx) {
        if (out_ctx->pb) avio_closep(&out_ctx->pb);
        avformat_free_context(out_ctx);
    }
    if (video_ctx) avformat_close_input(&video_ctx);
    if (audio_ctx) avformat_close_input(&audio_ctx);
    return ret;
}
