#define _GNU_SOURCE
#include "audio.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

#define RATE 48000
#define CHANNELS 2
#define PENDING (RATE / 5)

static struct {
	struct pw_thread_loop *loop;
	struct pw_stream *stream;
	struct spa_hook listener;
	AVFormatContext *fmt;
	AVCodecContext *ctx;
	SwrContext *swr;
	AVPacket *pkt;
	AVFrame *frame;
	int index;
	float pending[PENDING * CHANNELS];
	int have, used;
	float gain, target, step, volume;
	int inited;
	int cork;
	long delivered;
} A;

int wr_audio_opens(int enabled, float volume) {
	return enabled && volume > 0;
}

static int refill(void) {
	for (;;) {
		int r = avcodec_receive_frame(A.ctx, A.frame);
		if (r == 0) {
			uint8_t *out[1] = { (uint8_t *)A.pending };
			int got = swr_convert(A.swr, out, PENDING, (const uint8_t **)A.frame->extended_data, A.frame->nb_samples);
			av_frame_unref(A.frame);
			if (got <= 0) continue;
			A.have = got;
			A.used = 0;
			return 0;
		}
		if (r == AVERROR_EOF) {
			av_seek_frame(A.fmt, A.index, 0, AVSEEK_FLAG_BACKWARD);
			avcodec_flush_buffers(A.ctx);
			continue;
		}
		if (r != AVERROR(EAGAIN)) return -1;
		r = av_read_frame(A.fmt, A.pkt);
		if (r < 0) {
			avcodec_send_packet(A.ctx, NULL);
			continue;
		}
		if (A.pkt->stream_index == A.index) avcodec_send_packet(A.ctx, A.pkt);
		av_packet_unref(A.pkt);
	}
}

static void on_process(void *data) {
	(void)data;
	struct pw_buffer *b = pw_stream_dequeue_buffer(A.stream);
	if (!b) return;
	struct spa_buffer *buf = b->buffer;
	float *dst = buf->datas[0].data;
	if (!dst) return;
	uint32_t stride = sizeof(float) * CHANNELS;
	uint32_t frames = buf->datas[0].maxsize / stride;
	if (b->requested && b->requested < frames) frames = (uint32_t)b->requested;
	for (uint32_t i = 0; i < frames; i++) {
		if (A.used >= A.have && refill() != 0) {
			memset(dst + i * CHANNELS, 0, (frames - i) * stride);
			break;
		}
		if (A.step != 0) {
			A.gain += A.step;
			if ((A.step > 0 && A.gain >= A.target) || (A.step < 0 && A.gain <= A.target)) {
				A.gain = A.target;
				A.step = 0;
			}
		}
		float g = A.gain * A.gain * A.volume;
		for (int c = 0; c < CHANNELS; c++) dst[i * CHANNELS + c] = A.pending[A.used * CHANNELS + c] * g;
		A.used++;
	}
	buf->datas[0].chunk->offset = 0;
	buf->datas[0].chunk->stride = (int32_t)stride;
	buf->datas[0].chunk->size = frames * stride;
	A.delivered += frames;
	pw_stream_queue_buffer(A.stream, b);
	if (A.cork && A.gain <= 0) {
		A.cork = 0;
		pw_stream_set_active(A.stream, false);
	}
}

static const struct pw_stream_events events = {
	PW_VERSION_STREAM_EVENTS,
	.process = on_process,
};

static void close_decoder(void) {
	swr_free(&A.swr);
	av_frame_free(&A.frame);
	av_packet_free(&A.pkt);
	avcodec_free_context(&A.ctx);
	avformat_close_input(&A.fmt);
}

static int open_decoder(const char *path, double from) {
	if (avformat_open_input(&A.fmt, path, NULL, NULL) != 0) return -1;
	if (avformat_find_stream_info(A.fmt, NULL) < 0) goto fail;
	const AVCodec *codec = NULL;
	A.index = av_find_best_stream(A.fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
	if (A.index < 0 || !codec) goto fail;
	A.ctx = avcodec_alloc_context3(codec);
	if (!A.ctx || avcodec_parameters_to_context(A.ctx, A.fmt->streams[A.index]->codecpar) < 0) goto fail;
	if (avcodec_open2(A.ctx, codec, NULL) < 0) goto fail;
	AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
	if (swr_alloc_set_opts2(&A.swr, &stereo, AV_SAMPLE_FMT_FLT, RATE, &A.ctx->ch_layout, A.ctx->sample_fmt, A.ctx->sample_rate, 0, NULL) < 0 || swr_init(A.swr) < 0) goto fail;
	A.pkt = av_packet_alloc();
	A.frame = av_frame_alloc();
	if (!A.pkt || !A.frame) goto fail;
	if (from > 0) {
		AVStream *st = A.fmt->streams[A.index];
		av_seek_frame(A.fmt, A.index, (int64_t)(from / av_q2d(st->time_base)), AVSEEK_FLAG_BACKWARD);
	}
	A.have = A.used = 0;
	return 0;
fail:
	close_decoder();
	return -1;
}

int au_start(const char *path, double from, float volume, double fade) {
	au_stop();
	if (open_decoder(path, from) != 0) return -1;
	if (!A.inited) {
		pw_init(NULL, NULL);
		A.inited = 1;
	}
	A.loop = pw_thread_loop_new("yudae-wall-audio", NULL);
	if (!A.loop) {
		close_decoder();
		return -1;
	}
	A.volume = volume;
	A.delivered = 0;
	A.cork = 0;
	A.gain = 0;
	A.target = 1;
	A.step = fade > 0 ? (float)(1.0 / (fade * RATE)) : 1;
	A.stream = pw_stream_new_simple(pw_thread_loop_get_loop(A.loop), "Wallpaper",
		pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback", PW_KEY_MEDIA_ROLE, "Music", PW_KEY_APP_NAME, "yudae wallpaper", NULL),
		&events, NULL);
	if (!A.stream) {
		pw_thread_loop_destroy(A.loop);
		A.loop = NULL;
		close_decoder();
		return -1;
	}
	uint8_t buffer[1024];
	struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
	const struct spa_pod *params[1];
	struct spa_audio_info_raw info = { .format = SPA_AUDIO_FORMAT_F32, .channels = CHANNELS, .rate = RATE };
	params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info);
	pw_stream_connect(A.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
	pw_thread_loop_start(A.loop);
	return 0;
}

void au_fade(float target, double seconds) {
	if (!A.loop) return;
	pw_thread_loop_lock(A.loop);
	A.target = target;
	double samples = seconds * RATE;
	A.step = samples > 1 ? (float)((target - A.gain) / samples) : target - A.gain;
	if (A.step == 0) A.gain = target;
	pw_thread_loop_unlock(A.loop);
}

void au_pause(int paused) {
	if (!A.loop) return;
	pw_thread_loop_lock(A.loop);
	A.target = paused ? 0 : 1;
	A.step = (A.target - A.gain) / (0.3f * RATE);
	A.cork = paused;
	if (!paused) pw_stream_set_active(A.stream, true);
	pw_thread_loop_unlock(A.loop);
}

int au_running(void) {
	return A.loop != NULL;
}

void au_stop(void) {
	if (A.loop) {
		pw_thread_loop_stop(A.loop);
		pw_stream_destroy(A.stream);
		pw_thread_loop_destroy(A.loop);
		A.loop = NULL;
		A.stream = NULL;
	}
	close_decoder();
}

long au_delivered(void) {
	if (!A.loop) return -1;
	pw_thread_loop_lock(A.loop);
	long n = A.delivered;
	pw_thread_loop_unlock(A.loop);
	return n;
}
