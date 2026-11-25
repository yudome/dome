#pragma once

#include <stdint.h>

typedef struct {
	uint8_t *px;
	int w;
	int h;
} wr_image;

int wr_decode(const char *path, int want_w, int want_h, wr_image *out);
int wr_decode_at(const char *path, double seconds, wr_image *out);
int wr_is_video(const char *path);
void wr_image_free(wr_image *img);
int wr_jpeg_scale(int w, int h, int want_w, int want_h);
int wr_thumb(const char *path, double seconds, int px, int quality, const char *dest);
int wr_filmstrip(const char *path, int n, int px, const char *prefix, double *times, double *fps, double *duration);
