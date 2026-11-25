#define _GNU_SOURCE
#include "video.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <EGL/eglext.h>
#include <GLES2/gl2ext.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define FOURCC_R8 FOURCC('R', '8', ' ', ' ')
#define FOURCC_GR88 FOURCC('G', 'R', '8', '8')
#define MOD_INVALID 0x00ffffffffffffffULL

struct vdec {
	AVFormatContext *fmt;
	AVCodecContext *ctx;
	AVStream *st;
	int stream;
	AVBufferRef *hw;
	AVPacket *pkt;
	AVFrame *frame;
	AVFrame *sw;
	int eof;
	double duration;
	double fps;
	double start;
};

const char *video_frag_src =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D ty;\n"
	"uniform sampler2D tu;\n"
	"uniform sampler2D tv;\n"
	"uniform int planes;\n"
	"uniform mat3 m;\n"
	"uniform vec3 off;\n"
	"uniform vec2 coff;\n"
	"uniform vec2 cscl;\n"
	"in vec2 uv;\n"
	"out vec4 color;\n"
	"void main() {\n"
	"  vec2 t = coff + uv * cscl;\n"
	"  vec2 c = planes == 2 ? texture(tu, t).rg : vec2(texture(tu, t).r, texture(tv, t).r);\n"
	"  color = vec4(clamp(m * (vec3(texture(ty, t).r, c) - off), 0.0, 1.0), 1.0);\n"
	"}\n";

const char *video_ext_src =
	"#version 300 es\n"
	"#extension GL_OES_EGL_image_external_essl3 : require\n"
	"precision highp float;\n"
	"uniform samplerExternalOES te;\n"
	"uniform vec2 coff;\n"
	"uniform vec2 cscl;\n"
	"in vec2 uv;\n"
	"out vec4 color;\n"
	"void main() { color = vec4(texture(te, coff + uv * cscl).rgb, 1.0); }\n";

static enum AVPixelFormat pick_hw(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
	(void)ctx;
	for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
		if (*p == AV_PIX_FMT_VAAPI) return *p;
	return fmts[0];
}

vdec *vd_open(const char *path, int hw) {
	vdec *vd = calloc(1, sizeof *vd);
	if (!vd) return NULL;
	av_log_set_level(AV_LOG_FATAL);
	if (avformat_open_input(&vd->fmt, path, NULL, NULL) != 0) goto fail;
	if (avformat_find_stream_info(vd->fmt, NULL) < 0) goto fail;
	const AVCodec *codec = NULL;
	vd->stream = av_find_best_stream(vd->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
	if (vd->stream < 0 || !codec) goto fail;
	vd->st = vd->fmt->streams[vd->stream];
	vd->ctx = avcodec_alloc_context3(codec);
	if (!vd->ctx || avcodec_parameters_to_context(vd->ctx, vd->st->codecpar) < 0) goto fail;
	if (hw && av_hwdevice_ctx_create(&vd->hw, AV_HWDEVICE_TYPE_VAAPI, NULL, NULL, 0) == 0) {
		vd->ctx->hw_device_ctx = av_buffer_ref(vd->hw);
		vd->ctx->get_format = pick_hw;
	}
	vd->ctx->thread_count = 0;
	if (avcodec_open2(vd->ctx, codec, NULL) < 0) goto fail;
	vd->pkt = av_packet_alloc();
	vd->frame = av_frame_alloc();
	vd->sw = av_frame_alloc();
	if (!vd->pkt || !vd->frame || !vd->sw) goto fail;
	vd->start = vd->st->start_time != AV_NOPTS_VALUE ? vd->st->start_time * av_q2d(vd->st->time_base) : 0;
	if (vd->st->duration > 0) vd->duration = vd->st->duration * av_q2d(vd->st->time_base);
	else if (vd->fmt->duration > 0) vd->duration = vd->fmt->duration / (double)AV_TIME_BASE;
	AVRational rate = vd->st->avg_frame_rate.num ? vd->st->avg_frame_rate : vd->st->r_frame_rate;
	vd->fps = rate.num && rate.den ? av_q2d(rate) : 30;
	return vd;
fail:
	vd_close(vd);
	return NULL;
}

void vd_close(vdec *vd) {
	if (!vd) return;
	av_frame_free(&vd->frame);
	av_frame_free(&vd->sw);
	av_packet_free(&vd->pkt);
	avcodec_free_context(&vd->ctx);
	av_buffer_unref(&vd->hw);
	avformat_close_input(&vd->fmt);
	free(vd);
}

double vd_duration(vdec *vd) { return vd->duration; }
double vd_fps(vdec *vd) { return vd->fps; }
int vd_hw(vdec *vd) { return vd->hw != NULL; }
int vd_width(vdec *vd) { return vd->ctx->width; }
int vd_height(vdec *vd) { return vd->ctx->height; }

int vd_next(vdec *vd, AVFrame **out, double *pts) {
	for (;;) {
		av_frame_unref(vd->frame);
		int r = avcodec_receive_frame(vd->ctx, vd->frame);
		if (r == 0) {
			int64_t ts = vd->frame->best_effort_timestamp;
			*pts = ts == AV_NOPTS_VALUE ? 0 : ts * av_q2d(vd->st->time_base) - vd->start;
			*out = vd->frame;
			return 0;
		}
		if (r == AVERROR_EOF) return 1;
		if (r != AVERROR(EAGAIN)) return -1;
		if (vd->eof) return 1;
		r = av_read_frame(vd->fmt, vd->pkt);
		if (r < 0) {
			vd->eof = 1;
			avcodec_send_packet(vd->ctx, NULL);
			continue;
		}
		if (vd->pkt->stream_index == vd->stream) avcodec_send_packet(vd->ctx, vd->pkt);
		av_packet_unref(vd->pkt);
	}
}

int vd_seek(vdec *vd, double seconds) {
	int64_t ts = (int64_t)((seconds + vd->start) / av_q2d(vd->st->time_base));
	if (av_seek_frame(vd->fmt, vd->stream, ts, AVSEEK_FLAG_BACKWARD) < 0) {
		if (avformat_seek_file(vd->fmt, vd->stream, INT64_MIN, ts, ts, 0) < 0) return -1;
	}
	avcodec_flush_buffers(vd->ctx);
	vd->eof = 0;
	return 0;
}

static void set_matrix(vtex *vt, const AVFrame *f) {
	int full = f->color_range == AVCOL_RANGE_JPEG;
	int bt601 = f->colorspace == AVCOL_SPC_BT470BG || f->colorspace == AVCOL_SPC_SMPTE170M || (f->colorspace == AVCOL_SPC_UNSPECIFIED && f->height < 720);
	float ys = full ? 1.0f : 255.0f / 219.0f;
	float cs = full ? 1.0f : 255.0f / 224.0f;
	float kr = bt601 ? 0.299f : 0.2126f;
	float kb = bt601 ? 0.114f : 0.0722f;
	float kg = 1 - kr - kb;
	float rv = 2 * (1 - kr) * cs;
	float bu = 2 * (1 - kb) * cs;
	float gu = -bu * kb / kg;
	float gv = -rv * kr / kg;
	float m[9] = { ys, ys, ys, 0, gu, bu, rv, gv, 0 };
	memcpy(vt->matrix, m, sizeof m);
	vt->offset[0] = full ? 0 : 16.0f / 255;
	vt->offset[1] = vt->offset[2] = 128.0f / 255;
}

static GLuint plane_tex(GLuint t) {
	if (!t) glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	return t;
}

static void drop_images(vtex *vt, EGLDisplay egl) {
	PFNEGLDESTROYIMAGEKHRPROC destroy = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
	for (int i = 0; i < 3; i++) {
		if (vt->images[i] && destroy) destroy(egl, vt->images[i]);
		vt->images[i] = NULL;
	}
	av_frame_free(&vt->mapped);
}

static int import_prime(vtex *vt, EGLDisplay egl, AVFrame *frame) {
	static int broken;
	if (broken) return -1;
	PFNEGLCREATEIMAGEKHRPROC create = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (!create || !target) return broken = 1, -1;
	AVFrame *drm = av_frame_alloc();
	if (!drm) return -1;
	drm->format = AV_PIX_FMT_DRM_PRIME;
	if (av_hwframe_map(drm, frame, AV_HWFRAME_MAP_READ) < 0) {
		av_frame_free(&drm);
		return broken = 1, -1;
	}
	const AVDRMFrameDescriptor *d = (const AVDRMFrameDescriptor *)drm->data[0];
	struct { int obj; ptrdiff_t off, pitch; } planes[2];
	int n = 0;
	for (int l = 0; l < d->nb_layers && n < 2; l++)
		for (int p = 0; p < d->layers[l].nb_planes && n < 2; p++, n++) {
			planes[n].obj = d->layers[l].planes[p].object_index;
			planes[n].off = d->layers[l].planes[p].offset;
			planes[n].pitch = d->layers[l].planes[p].pitch;
		}
	if (n != 2) {
		av_frame_free(&drm);
		return broken = 1, -1;
	}
	drop_images(vt, egl);
	int full = frame->color_range == AVCOL_RANGE_JPEG;
	int bt601 = frame->colorspace == AVCOL_SPC_BT470BG || frame->colorspace == AVCOL_SPC_SMPTE170M;
	EGLint attrs[48];
	int k = 0;
	attrs[k++] = EGL_WIDTH;
	attrs[k++] = frame->width;
	attrs[k++] = EGL_HEIGHT;
	attrs[k++] = frame->height;
	attrs[k++] = EGL_LINUX_DRM_FOURCC_EXT;
	attrs[k++] = (EGLint)FOURCC('N', 'V', '1', '2');
	attrs[k++] = EGL_YUV_COLOR_SPACE_HINT_EXT;
	attrs[k++] = bt601 ? EGL_ITU_REC601_EXT : EGL_ITU_REC709_EXT;
	attrs[k++] = EGL_SAMPLE_RANGE_HINT_EXT;
	attrs[k++] = full ? EGL_YUV_FULL_RANGE_EXT : EGL_YUV_NARROW_RANGE_EXT;
	const EGLint keys[2][5] = {
		{ EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT },
		{ EGL_DMA_BUF_PLANE1_FD_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT },
	};
	for (int i = 0; i < 2; i++) {
		uint64_t mod = d->objects[planes[i].obj].format_modifier;
		attrs[k++] = keys[i][0];
		attrs[k++] = d->objects[planes[i].obj].fd;
		attrs[k++] = keys[i][1];
		attrs[k++] = (EGLint)planes[i].off;
		attrs[k++] = keys[i][2];
		attrs[k++] = (EGLint)planes[i].pitch;
		if (mod != MOD_INVALID) {
			attrs[k++] = keys[i][3];
			attrs[k++] = (EGLint)(mod & 0xffffffff);
			attrs[k++] = keys[i][4];
			attrs[k++] = (EGLint)(mod >> 32);
		}
	}
	attrs[k++] = EGL_NONE;
	vt->images[0] = create(egl, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	if (!vt->images[0]) {
		fprintf(stderr, "yudaemond: wallpaper dmabuf import failed (0x%x), copying frames\n", eglGetError());
		av_frame_free(&drm);
		return broken = 1, -1;
	}
	if (!vt->ext) glGenTextures(1, &vt->ext);
	glBindTexture(GL_TEXTURE_EXTERNAL_OES, vt->ext);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	target(GL_TEXTURE_EXTERNAL_OES, vt->images[0]);
	vt->mapped = drm;
	vt->planes = 0;
	vt->zero_copy = 1;
	return 0;
}

static void upload_plane(GLuint *t, GLenum fmt, int w, int h, const uint8_t *data, int stride, int bpp) {
	*t = plane_tex(*t);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, stride / bpp);
	glTexImage2D(GL_TEXTURE_2D, 0, fmt == GL_RG ? GL_RG8 : GL_R8, w, h, 0, fmt, GL_UNSIGNED_BYTE, data);
	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
}

int vt_upload(vtex *vt, EGLDisplay egl, AVFrame *frame) {
	vt->w = frame->width;
	vt->h = frame->height;
	set_matrix(vt, frame);
	AVFrame *src = frame;
	AVFrame *tmp = NULL;
	if (frame->format == AV_PIX_FMT_VAAPI) {
		if (import_prime(vt, egl, frame) == 0) return 0;
		tmp = av_frame_alloc();
		if (!tmp || av_hwframe_transfer_data(tmp, frame, 0) < 0) {
			av_frame_free(&tmp);
			return -1;
		}
		src = tmp;
	}
	drop_images(vt, egl);
	vt->zero_copy = 0;
	if (src->format != AV_PIX_FMT_NV12 && src->format != AV_PIX_FMT_YUV420P && src->format != AV_PIX_FMT_YUVJ420P) {
		AVFrame *conv = av_frame_alloc();
		conv->format = AV_PIX_FMT_YUV420P;
		conv->width = src->width;
		conv->height = src->height;
		struct SwsContext *sws = sws_getContext(src->width, src->height, src->format, src->width, src->height, AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
		if (!sws || av_frame_get_buffer(conv, 0) < 0) {
			sws_freeContext(sws);
			av_frame_free(&conv);
			av_frame_free(&tmp);
			return -1;
		}
		sws_scale(sws, (const uint8_t *const *)src->data, src->linesize, 0, src->height, conv->data, conv->linesize);
		sws_freeContext(sws);
		av_frame_free(&tmp);
		tmp = conv;
		src = conv;
	}
	int cw = (src->width + 1) / 2, ch = (src->height + 1) / 2;
	upload_plane(&vt->tex[0], GL_RED, src->width, src->height, src->data[0], src->linesize[0], 1);
	if (src->format == AV_PIX_FMT_NV12) {
		upload_plane(&vt->tex[1], GL_RG, cw, ch, src->data[1], src->linesize[1], 2);
		vt->planes = 2;
	} else {
		upload_plane(&vt->tex[1], GL_RED, cw, ch, src->data[1], src->linesize[1], 1);
		upload_plane(&vt->tex[2], GL_RED, cw, ch, src->data[2], src->linesize[2], 1);
		vt->planes = 3;
	}
	av_frame_free(&tmp);
	return 0;
}

void vt_free(vtex *vt, EGLDisplay egl) {
	drop_images(vt, egl);
	for (int i = 0; i < 3; i++)
		if (vt->tex[i]) glDeleteTextures(1, &vt->tex[i]);
	if (vt->ext) glDeleteTextures(1, &vt->ext);
	memset(vt, 0, sizeof *vt);
}

void vt_bind(vtex *vt, GLuint prog) {
	if (vt->planes == 0) {
		glActiveTexture(GL_TEXTURE0);
		glBindTexture(GL_TEXTURE_EXTERNAL_OES, vt->ext);
		glUniform1i(glGetUniformLocation(prog, "te"), 0);
		return;
	}
	for (int i = 0; i < 3; i++) {
		glActiveTexture(GL_TEXTURE0 + i);
		glBindTexture(GL_TEXTURE_2D, vt->tex[i < vt->planes ? i : 0]);
	}
	glUniform1i(glGetUniformLocation(prog, "ty"), 0);
	glUniform1i(glGetUniformLocation(prog, "tu"), 1);
	glUniform1i(glGetUniformLocation(prog, "tv"), 2);
	glUniform1i(glGetUniformLocation(prog, "planes"), vt->planes);
	glUniformMatrix3fv(glGetUniformLocation(prog, "m"), 1, GL_FALSE, vt->matrix);
	glUniform3fv(glGetUniformLocation(prog, "off"), 1, vt->offset);
}
