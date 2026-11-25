#define _GNU_SOURCE
#include "imgdecode.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

#include <turbojpeg.h>
#include <webp/decode.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#include "wuffs-v0.4.c"

#define MAX_DIM 16384

void wr_image_free(wr_image *img) {
	free(img->px);
	img->px = NULL;
	img->w = img->h = 0;
}

int wr_jpeg_scale(int w, int h, int want_w, int want_h) {
	int best = 1;
	for (int d = 2; d <= 8; d *= 2) {
		int sw = (w + d - 1) / d;
		int sh = (h + d - 1) / d;
		if (sw >= want_w && sh >= want_h) best = d;
	}
	return best;
}

static int sane(int w, int h) {
	return w > 0 && h > 0 && w <= MAX_DIM && h <= MAX_DIM;
}

static int decode_jpeg(const uint8_t *data, size_t len, int want_w, int want_h, wr_image *out) {
	tjhandle tj = tj3Init(TJINIT_DECOMPRESS);
	if (!tj) return -1;
	int rc = -1;
	if (tj3DecompressHeader(tj, data, len) != 0) goto done;
	int w = tj3Get(tj, TJPARAM_JPEGWIDTH);
	int h = tj3Get(tj, TJPARAM_JPEGHEIGHT);
	if (w <= 0 || h <= 0) goto done;
	int d = want_w > 0 && want_h > 0 ? wr_jpeg_scale(w, h, want_w, want_h) : 1;
	tjscalingfactor sf = { 1, d };
	if (tj3SetScalingFactor(tj, sf) != 0) goto done;
	int sw = TJSCALED(w, sf);
	int sh = TJSCALED(h, sf);
	if (!sane(sw, sh)) goto done;
	uint8_t *px = malloc((size_t)sw * sh * 4);
	if (!px) goto done;
	if (tj3Decompress8(tj, data, len, px, sw * 4, TJPF_RGBA) != 0) {
		free(px);
		goto done;
	}
	out->px = px;
	out->w = sw;
	out->h = sh;
	rc = 0;
done:
	tj3Destroy(tj);
	return rc;
}

static int decode_png(const uint8_t *data, size_t len, wr_image *out) {
	wuffs_png__decoder *dec = malloc(sizeof__wuffs_png__decoder());
	if (!dec) return -1;
	int rc = -1;
	uint8_t *work = NULL;
	uint8_t *px = NULL;
	wuffs_base__status st = wuffs_png__decoder__initialize(dec, sizeof__wuffs_png__decoder(), WUFFS_VERSION, WUFFS_INITIALIZE__LEAVE_INTERNAL_BUFFERS_UNINITIALIZED);
	if (st.repr) goto done;
	wuffs_png__decoder__set_quirk(dec, WUFFS_BASE__QUIRK_IGNORE_CHECKSUM, 1);
	wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)data, len, true);
	wuffs_base__image_config ic;
	st = wuffs_png__decoder__decode_image_config(dec, &ic, &src);
	if (st.repr) goto done;
	uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
	uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
	if (!sane((int)w, (int)h)) goto done;
	wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
	uint64_t wlen = wuffs_png__decoder__workbuf_len(dec).max_incl;
	work = malloc(wlen ? wlen : 1);
	px = malloc((size_t)w * h * 4);
	if (!work || !px) goto done;
	wuffs_base__pixel_buffer pb;
	st = wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(px, (size_t)w * h * 4));
	if (st.repr) goto done;
	st = wuffs_png__decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC, wuffs_base__make_slice_u8(work, wlen), NULL);
	if (st.repr) goto done;
	out->px = px;
	out->w = (int)w;
	out->h = (int)h;
	px = NULL;
	rc = 0;
done:
	free(px);
	free(work);
	free(dec);
	return rc;
}

static int decode_webp(const uint8_t *data, size_t len, wr_image *out) {
	int w = 0, h = 0;
	if (!WebPGetInfo(data, len, &w, &h) || !sane(w, h)) return -1;
	uint8_t *px = malloc((size_t)w * h * 4);
	if (!px) return -1;
	if (!WebPDecodeRGBAInto(data, len, px, (size_t)w * h * 4, w * 4)) {
		free(px);
		return -1;
	}
	out->px = px;
	out->w = w;
	out->h = h;
	return 0;
}

static int frame_to_rgba(AVFrame *frame, wr_image *out) {
	if (!sane(frame->width, frame->height)) return -1;
	struct SwsContext *sws = sws_getContext(frame->width, frame->height, frame->format, frame->width, frame->height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
	if (!sws) return -1;
	uint8_t *px = malloc((size_t)frame->width * frame->height * 4);
	if (!px) {
		sws_freeContext(sws);
		return -1;
	}
	uint8_t *dst[4] = { px, NULL, NULL, NULL };
	int stride[4] = { frame->width * 4, 0, 0, 0 };
	sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, dst, stride);
	sws_freeContext(sws);
	out->px = px;
	out->w = frame->width;
	out->h = frame->height;
	return 0;
}

int wr_decode_at(const char *path, double seconds, wr_image *out) {
	out->px = NULL;
	out->w = out->h = 0;
	AVFormatContext *fmt = NULL;
	AVCodecContext *ctx = NULL;
	AVPacket *pkt = NULL;
	AVFrame *frame = NULL;
	int rc = -1;
	av_log_set_level(AV_LOG_FATAL);
	if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return -1;
	if (avformat_find_stream_info(fmt, NULL) < 0) goto done;
	const AVCodec *codec = NULL;
	int index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
	if (index < 0 || !codec) goto done;
	AVStream *stream = fmt->streams[index];
	ctx = avcodec_alloc_context3(codec);
	if (!ctx || avcodec_parameters_to_context(ctx, stream->codecpar) < 0) goto done;
	if (avcodec_open2(ctx, codec, NULL) < 0) goto done;
	int64_t target = AV_NOPTS_VALUE;
	if (seconds > 0) {
		target = (int64_t)(seconds / av_q2d(stream->time_base));
		if (stream->start_time != AV_NOPTS_VALUE) target += stream->start_time;
		av_seek_frame(fmt, index, target, AVSEEK_FLAG_BACKWARD);
		avcodec_flush_buffers(ctx);
	}
	pkt = av_packet_alloc();
	frame = av_frame_alloc();
	if (!pkt || !frame) goto done;
	AVFrame *best = NULL;
	int eof = 0;
	while (!best) {
		if (!eof) {
			int r = av_read_frame(fmt, pkt);
			if (r < 0) {
				eof = 1;
				avcodec_send_packet(ctx, NULL);
			} else {
				if (pkt->stream_index == index) avcodec_send_packet(ctx, pkt);
				av_packet_unref(pkt);
			}
		}
		for (;;) {
			int r = avcodec_receive_frame(ctx, frame);
			if (r != 0) {
				if (r == AVERROR_EOF) eof = 2;
				break;
			}
			int64_t pts = frame->best_effort_timestamp;
			if (target == AV_NOPTS_VALUE || pts == AV_NOPTS_VALUE || pts >= target) {
				best = frame;
				break;
			}
			av_frame_unref(frame);
		}
		if (eof == 2) break;
	}
	if (best) rc = frame_to_rgba(best, out);
done:
	av_frame_free(&frame);
	av_packet_free(&pkt);
	avcodec_free_context(&ctx);
	avformat_close_input(&fmt);
	return rc;
}

int wr_is_video(const char *path) {
	const char *dot = strrchr(path, '.');
	if (!dot) return 0;
	return !strcasecmp(dot, ".mp4") || !strcasecmp(dot, ".webm") || !strcasecmp(dot, ".mkv") || !strcasecmp(dot, ".mov");
}

int wr_decode(const char *path, int want_w, int want_h, wr_image *out) {
	out->px = NULL;
	out->w = out->h = 0;
	if (wr_is_video(path)) return wr_decode_at(path, 0, out);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	struct stat st;
	if (fstat(fd, &st) != 0 || st.st_size < 12) {
		close(fd);
		return -1;
	}
	size_t len = (size_t)st.st_size;
	uint8_t *data = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	if (data == MAP_FAILED) return -1;
	int rc;
	if (data[0] == 0xff && data[1] == 0xd8)
		rc = decode_jpeg(data, len, want_w, want_h, out);
	else if (!memcmp(data, "\x89PNG", 4))
		rc = decode_png(data, len, out);
	else if (!memcmp(data, "RIFF", 4) && !memcmp(data + 8, "WEBP", 4))
		rc = decode_webp(data, len, out);
	else
		rc = 1;
	munmap(data, len);
	if (rc == 1) rc = wr_decode_at(path, 0, out);
	return rc;
}

static int save_fit(wr_image *img, int px, int quality, const char *dest) {
	double s = fmin(1.0, fmin((double)px / img->w, (double)px / img->h));
	int w = img->w * s < 1 ? 1 : (int)(img->w * s + 0.5);
	int h = img->h * s < 1 ? 1 : (int)(img->h * s + 0.5);
	uint8_t *small = malloc((size_t)w * h * 4);
	struct SwsContext *sws = small ? sws_getContext(img->w, img->h, AV_PIX_FMT_RGBA, w, h, AV_PIX_FMT_RGBA, SWS_AREA, NULL, NULL, NULL) : NULL;
	if (!sws) {
		free(small);
		return -1;
	}
	const uint8_t *src[4] = { img->px, NULL, NULL, NULL };
	int sstride[4] = { img->w * 4, 0, 0, 0 };
	uint8_t *dst[4] = { small, NULL, NULL, NULL };
	int dstride[4] = { w * 4, 0, 0, 0 };
	sws_scale(sws, src, sstride, 0, img->h, dst, dstride);
	sws_freeContext(sws);
	tjhandle tj = tj3Init(TJINIT_COMPRESS);
	unsigned char *jpeg = NULL;
	size_t size = 0;
	int rc = -1;
	if (tj && tj3Set(tj, TJPARAM_QUALITY, quality) == 0 && tj3Set(tj, TJPARAM_SUBSAMP, TJSAMP_420) == 0 &&
	    tj3Compress8(tj, small, w, w * 4, h, TJPF_RGBA, &jpeg, &size) == 0) {
		char part[4200];
		snprintf(part, sizeof part, "%s.part", dest);
		FILE *f = fopen(part, "wb");
		if (f) {
			int ok = fwrite(jpeg, 1, size, f) == size;
			ok = fclose(f) == 0 && ok;
			if (ok && rename(part, dest) == 0) rc = 0;
			else unlink(part);
		}
	}
	tj3Free(jpeg);
	tj3Destroy(tj);
	free(small);
	return rc;
}

int wr_thumb(const char *path, double seconds, int px, int quality, const char *dest) {
	wr_image img;
	int rc = wr_is_video(path) ? wr_decode_at(path, seconds, &img) : wr_decode(path, px, px, &img);
	if (rc != 0) return -1;
	rc = save_fit(&img, px, quality, dest);
	wr_image_free(&img);
	return rc;
}

int wr_filmstrip(const char *path, int n, int px, const char *prefix, double *times, double *fps, double *duration) {
	AVFormatContext *fmt = NULL;
	AVCodecContext *ctx = NULL;
	AVPacket *pkt = NULL;
	AVFrame *frame = NULL;
	int count = 0;
	av_log_set_level(AV_LOG_FATAL);
	if (avformat_open_input(&fmt, path, NULL, NULL) != 0) return -1;
	if (avformat_find_stream_info(fmt, NULL) < 0) goto done;
	const AVCodec *codec = NULL;
	int index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
	if (index < 0 || !codec) goto done;
	AVStream *st = fmt->streams[index];
	ctx = avcodec_alloc_context3(codec);
	if (!ctx || avcodec_parameters_to_context(ctx, st->codecpar) < 0) goto done;
	ctx->skip_frame = AVDISCARD_NONKEY;
	ctx->thread_count = 1;
	if (avcodec_open2(ctx, codec, NULL) < 0) goto done;
	double start = st->start_time != AV_NOPTS_VALUE ? st->start_time * av_q2d(st->time_base) : 0;
	double dur = st->duration > 0 ? st->duration * av_q2d(st->time_base) : fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
	AVRational rate = st->avg_frame_rate.num ? st->avg_frame_rate : st->r_frame_rate;
	*fps = rate.num && rate.den ? av_q2d(rate) : 30;
	*duration = dur;
	pkt = av_packet_alloc();
	frame = av_frame_alloc();
	if (!pkt || !frame) goto done;
	for (int i = 0; i < n; i++) {
		double want = dur * i / n;
		av_seek_frame(fmt, index, (int64_t)((want + start) / av_q2d(st->time_base)), AVSEEK_FLAG_BACKWARD);
		avcodec_flush_buffers(ctx);
		int got = 0;
		while (!got && av_read_frame(fmt, pkt) >= 0) {
			if (pkt->stream_index == index && avcodec_send_packet(ctx, pkt) == 0 && avcodec_receive_frame(ctx, frame) == 0) got = 1;
			av_packet_unref(pkt);
		}
		if (!got && avcodec_send_packet(ctx, NULL) == 0 && avcodec_receive_frame(ctx, frame) == 0) got = 1;
		if (!got) continue;
		double t = frame->best_effort_timestamp * av_q2d(st->time_base) - start;
		if (count > 0 && fabs(t - times[count - 1]) < 1e-3) {
			av_frame_unref(frame);
			continue;
		}
		wr_image img;
		if (frame_to_rgba(frame, &img) == 0) {
			char dest[4200];
			snprintf(dest, sizeof dest, "%s%02d.jpg", prefix, count);
			if (save_fit(&img, px, 75, dest) == 0) times[count++] = t;
			wr_image_free(&img);
		}
		av_frame_unref(frame);
	}
done:
	av_frame_free(&frame);
	av_packet_free(&pkt);
	avcodec_free_context(&ctx);
	avformat_close_input(&fmt);
	return count;
}
