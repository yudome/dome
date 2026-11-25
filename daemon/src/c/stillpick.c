#define _GNU_SOURCE
#include "stillpick.h"
#include "video.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>

#define PW 160
#define PH 90

static int cmp_float(const void *a, const void *b) {
	float x = *(const float *)a, y = *(const float *)b;
	return (x > y) - (x < y);
}

static float percentile(const float *v, int n, double p) {
	if (n <= 0) return 0;
	float *c = malloc(sizeof *c * n);
	if (!c) return 0;
	memcpy(c, v, sizeof *c * n);
	qsort(c, n, sizeof *c, cmp_float);
	float r = c[(int)(p * (n - 1))];
	free(c);
	return r;
}

int wr_pick_index(const wr_frame_stats *s, int n, double fps, int *settle_ms, float *curve) {
	if (n <= 0) return -1;
	float *motion = malloc(sizeof *motion * n);
	float *sharp = malloc(sizeof *sharp * n);
	char *cut = calloc(n, 1);
	if (!motion || !sharp || !cut) {
		free(motion);
		free(sharp);
		free(cut);
		return 0;
	}
	for (int i = 0; i < n; i++) {
		motion[i] = s[i].motion;
		sharp[i] = s[i].sharp;
	}
	float med = percentile(motion, n, 0.5);
	float p90 = percentile(motion, n, 0.9);
	float sharp90 = percentile(sharp, n, 0.9);
	float cut_at = fmaxf(med * 6, 0.12f);
	int guard = (int)ceil(fps * 0.5);
	for (int i = 1; i < n; i++)
		if (s[i].motion > cut_at)
			for (int j = i - guard; j <= i + guard; j++)
				if (j >= 0 && j < n) cut[j] = 1;
	int window = (int)ceil(fps);
	if (window < 2) window = 2;
	double scale = p90 > 1e-6 ? p90 : 1e-6;
	int best = -1;
	double best_score = -1e9, best_before = 0;
	for (int i = 0; i < n; i++) {
		if (cut[i]) continue;
		double before = 0;
		int k = 0;
		for (int j = i - window; j < i; j++)
			if (j >= 0) {
				before += s[j].motion;
				k++;
			}
		before = k ? before / k : s[i].motion;
		double still = 1 - fmin(1, s[i].motion / scale);
		double decay = fmax(0, fmin(1, (before - s[i].motion) / scale));
		double crisp = sharp90 > 1e-6 ? fmin(1, s[i].sharp / sharp90) : 0;
		double light = s[i].bright < 0.12 ? s[i].bright / 0.12 : s[i].bright > 0.9 ? (1 - s[i].bright) / 0.1 : 1;
		double contrast = fmin(1, s[i].contrast / 0.2);
		double score = 1.2 * still + 1.0 * decay + 1.0 * crisp + 0.6 * contrast + 1.5 * light;
		if (score > best_score) {
			best_score = score;
			best = i;
			best_before = before / scale;
		}
	}
	if (best < 0) best = 0;
	if (settle_ms) {
		int ms = (int)(600 + 1900 * fmin(1, fmax(0, best_before)));
		*settle_ms = ms < 600 ? 600 : ms > 2500 ? 2500 : ms;
	}
	if (curve) *curve = best_before > 0.6 ? 3.0f : 2.0f;
	free(motion);
	free(sharp);
	free(cut);
	return best;
}

static void stats_of(const uint8_t *g, const uint8_t *prev, wr_frame_stats *st) {
	double sum = 0, sq = 0, diff = 0, lap = 0;
	for (int y = 0; y < PH; y++)
		for (int x = 0; x < PW; x++) {
			double v = g[y * PW + x] / 255.0;
			sum += v;
			sq += v * v;
			if (prev) diff += fabs(v - prev[y * PW + x] / 255.0);
			if (x > 0 && y > 0 && x < PW - 1 && y < PH - 1) {
				int c = g[y * PW + x];
				int l = 4 * c - g[y * PW + x - 1] - g[y * PW + x + 1] - g[(y - 1) * PW + x] - g[(y + 1) * PW + x];
				lap += abs(l) / 255.0;
			}
		}
	double n = PW * PH;
	st->bright = (float)(sum / n);
	st->contrast = (float)sqrt(fmax(0, sq / n - (sum / n) * (sum / n)));
	st->motion = prev ? (float)(diff / n) : 0;
	st->sharp = (float)(lap / ((PW - 2) * (PH - 2)));
	double top = 0;
	for (int i = 0; i < PW * 3; i++) top += g[i];
	st->top = (float)(top / (PW * 3) / 255.0);
}

int wr_analyze(const char *path, wr_pick *out) {
	memset(out, 0, sizeof *out);
	setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), 19);
	vdec *vd = vd_open(path, 1);
	if (!vd) return -1;
	int cap = 1024, n = 0;
	wr_frame_stats *stats = malloc(sizeof *stats * cap);
	double *times = malloc(sizeof *times * cap);
	uint8_t *gray[2] = { malloc(PW * PH), malloc(PW * PH) };
	AVFrame *sw = av_frame_alloc();
	struct SwsContext *sws = NULL;
	int rc = -1;
	if (!stats || !times || !gray[0] || !gray[1] || !sw) goto done;
	AVFrame *f;
	double pts;
	while (vd_next(vd, &f, &pts) == 0) {
		AVFrame *src = f;
		if (f->format == AV_PIX_FMT_VAAPI) {
			av_frame_unref(sw);
			if (av_hwframe_transfer_data(sw, f, 0) < 0) break;
			src = sw;
		}
		sws = sws_getCachedContext(sws, src->width, src->height, src->format, PW, PH, AV_PIX_FMT_GRAY8, SWS_AREA, NULL, NULL, NULL);
		if (!sws) break;
		if (n == cap) {
			int grow = cap * 2;
			wr_frame_stats *ns = realloc(stats, sizeof *stats * grow);
			if (!ns) break;
			stats = ns;
			double *nt = realloc(times, sizeof *times * grow);
			if (!nt) break;
			times = nt;
			cap = grow;
		}
		uint8_t *dst[4] = { gray[n & 1], NULL, NULL, NULL };
		int stride[4] = { PW, 0, 0, 0 };
		sws_scale(sws, (const uint8_t *const *)src->data, src->linesize, 0, src->height, dst, stride);
		stats_of(gray[n & 1], n ? gray[(n + 1) & 1] : NULL, &stats[n]);
		times[n] = pts;
		n++;
	}
	if (n > 0) {
		int i = wr_pick_index(stats, n, vd_fps(vd), &out->settle_ms, &out->curve);
		out->frame = times[i];
		out->frames = n;
		out->top = stats[i].top;
		rc = 0;
	}
done:
	sws_freeContext(sws);
	av_frame_free(&sw);
	free(gray[0]);
	free(gray[1]);
	free(stats);
	free(times);
	vd_close(vd);
	return rc;
}
