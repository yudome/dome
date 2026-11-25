#pragma once

#include <EGL/egl.h>
#include <GLES3/gl3.h>

struct AVFrame;

typedef struct vdec vdec;

typedef struct {
	GLuint tex[3];
	int planes;
	int w, h;
	float matrix[9];
	float offset[3];
	EGLImage images[3];
	struct AVFrame *mapped;
	int zero_copy;
	GLuint ext;
} vtex;

vdec *vd_open(const char *path, int hw);
void vd_close(vdec *vd);
int vd_next(vdec *vd, struct AVFrame **frame, double *pts);
int vd_seek(vdec *vd, double seconds);
double vd_duration(vdec *vd);
double vd_fps(vdec *vd);
int vd_hw(vdec *vd);
int vd_width(vdec *vd);
int vd_height(vdec *vd);

int vt_upload(vtex *vt, EGLDisplay egl, struct AVFrame *frame);
void vt_free(vtex *vt, EGLDisplay egl);
void vt_bind(vtex *vt, GLuint prog);

extern const char *video_frag_src;
extern const char *video_ext_src;
