#pragma once

typedef struct {
	float motion;
	float sharp;
	float bright;
	float contrast;
	float top;
} wr_frame_stats;

typedef struct {
	double frame;
	int settle_ms;
	float curve;
	int frames;
	float top;
} wr_pick;

int wr_pick_index(const wr_frame_stats *stats, int n, double fps, int *settle_ms, float *curve);
int wr_analyze(const char *path, wr_pick *out);
