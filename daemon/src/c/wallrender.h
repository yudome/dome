#pragma once

#include <stdint.h>

#define WR_MAX_OPTS 16

enum {
	WR_EVENT_INK = 1,
	WR_EVENT_GONE = 2,
	WR_EVENT_SHOWN = 3,
};

typedef void (*wr_event_fn)(void *ctx, int kind, const char *output, const char *path, double luma);

typedef struct {
	const char *path;
	const char *output;
	const char *shader;
	int duration_ms;
	float bezier[4];
	float ink_at;
	int band;
	int n_opts;
	const char *opt_names[WR_MAX_OPTS];
	float opt_vals[WR_MAX_OPTS];
	int loop;
	double still;
	int settle_ms;
	float curve;
	int audio;
	float volume;
} wr_request;

int wr_start(void *ctx, wr_event_fn event);
void wr_apply(const wr_request *req);
void wr_band(int band);
void wr_play(void);
void wr_settle(void);
void wr_pause(int paused);
void wr_still(double seconds);
double wr_settle_pos(double u, double curve);
double wr_settle_target(double now, double still, double dur, double travel);

double wr_bezier(const float p[4], double x);
double wr_band_luma(const uint8_t *rgba, int width, int rows);
int wr_is_black(double luma);
int wr_band_rows(int band, int scale120, int height);
void wr_cover(int iw, int ih, int bw, int bh, float off[2], float scl[2]);
int wr_check_shader(const char *src, char *err, int len);

typedef struct {
	int frames;
	double seconds;
	int hw;
	int zero_copy;
	int width;
	int height;
	double fps;
	double mean[3];
} wr_video_bench;

int wr_bench_video(const char *path, int frames, int hw, wr_video_bench *out);

typedef struct {
	long commits;
	long decoded;
	long presented;
	long dropped;
	long settles;
	double landed_error;
	int mode;
	int paused;
	int gl;
	double position;
} wr_stats;

void wr_get_stats(wr_stats *out);
