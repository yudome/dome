#define _GNU_SOURCE
#include "wallrender.h"
#include "imgdecode.h"
#include "video.h"
#include "audio.h"

#include <dirent.h>
#include <errno.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <libavutil/frame.h>

#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "fractional-scale-v1-client-protocol.h"

#define LOG(...) fprintf(stderr, "yudaemond: wallpaper " __VA_ARGS__)

double wr_bezier(const float p[4], double x) {
	if (x <= 0) return 0;
	if (x >= 1) return 1;
	double lo = 0, hi = 1, t = x;
	for (int i = 0; i < 40; i++) {
		t = (lo + hi) / 2;
		double u = 1 - t;
		double bx = 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t * t * t;
		if (bx < x) lo = t;
		else hi = t;
	}
	double u = 1 - t;
	return 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t * t * t;
}

static double lin_table[256];
static pthread_once_t lin_once = PTHREAD_ONCE_INIT;

static void lin_init(void) {
	for (int i = 0; i < 256; i++) {
		double c = i / 255.0;
		lin_table[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
	}
}

double wr_band_luma(const uint8_t *rgba, int width, int rows) {
	pthread_once(&lin_once, lin_init);
	if (width <= 0 || rows <= 0) return -1;
	double sum = 0;
	size_t n = (size_t)width * rows;
	for (size_t i = 0; i < n; i++) {
		const uint8_t *px = rgba + i * 4;
		sum += 0.2126 * lin_table[px[0]] + 0.7152 * lin_table[px[1]] + 0.0722 * lin_table[px[2]];
	}
	return sum / n;
}

int wr_is_black(double y) {
	return (y + 0.05) / 0.05 >= 1.05 / (y + 0.05);
}

int wr_band_rows(int band, int scale120, int height) {
	if (band <= 0) return 0;
	int rows = (band * scale120 + 119) / 120;
	if (rows > height) rows = height;
	return rows;
}

void wr_cover(int iw, int ih, int bw, int bh, float off[2], float scl[2]) {
	double s = fmax((double)bw / iw, (double)bh / ih);
	double vw = bw / s, vh = bh / s;
	scl[0] = (float)(vw / iw);
	scl[1] = (float)(vh / ih);
	off[0] = (float)((iw - vw) / 2 / iw);
	off[1] = (float)((ih - vh) / 2 / ih);
}

struct shm {
	struct wl_buffer *buf;
	uint8_t *data;
	size_t size;
	int w, h;
};

struct req {
	struct req *next;
	int kind;
	char *path;
	char *output;
	char *shader;
	int duration_ms;
	float bezier[4];
	float ink_at;
	int band;
	int n_opts;
	char *opt_names[WR_MAX_OPTS];
	float opt_vals[WR_MAX_OPTS];
	int loop;
	double still;
	int settle_ms;
	float curve;
	int play;
	int audio;
	float volume;
};

struct out {
	struct wl_list link;
	uint32_t gname;
	struct wl_output *wl;
	char name[64];
	int int_scale;
	int scale120;
	struct wl_surface *surf;
	struct zwlr_layer_surface_v1 *layer;
	struct wp_viewport *vp;
	struct wp_fractional_scale_v1 *frac;
	int lw, lh;
	int configured;
	int dirty;
	struct shm shown;
	char path[4096];
	double luma;
	struct shm next;
	char next_path[4096];
	double next_luma;
	int animating;
	double t0;
	struct wl_egl_window *ew;
	EGLSurface es;
	GLuint old_tex, new_tex;
	int ink_fired;
	int frames;
	double ink_t;
	struct wl_callback *cb;
	struct req *anim;
	int video;
	int vdirty;
	struct shm still;
	double still_luma;
};

static struct {
	void *ctx;
	wr_event_fn event;
	pthread_mutex_t lock;
	struct req *head, *tail;
	int efd;
	char *last_path;
	int band;
	struct wl_display *dpy;
	struct wl_registry *reg;
	struct wl_compositor *comp;
	struct wl_shm *shm;
	struct zwlr_layer_shell_v1 *layer_shell;
	struct wp_viewporter *viewporter;
	struct wp_fractional_scale_manager_v1 *frac_mgr;
	struct wl_list outs;
	EGLDisplay egl;
	EGLConfig cfg;
	EGLContext ctxgl;
	GLuint cover_prog;
	GLuint trans_prog;
	GLuint fbo;
	struct req *trans_req;
} W = { .lock = PTHREAD_MUTEX_INITIALIZER, .efd = -1 };

static wr_stats S;


static void count(long *field) {
	pthread_mutex_lock(&W.lock);
	(*field)++;
	pthread_mutex_unlock(&W.lock);
}

enum { V_OFF, V_PENDING, V_PLAY, V_STILL };
enum { SEG_LINEAR, SEG_DOWN, SEG_UP };

static struct {
	char path[4096];
	int loop;
	double still;
	double settle;
	double curve;
	int mode;
	int paused;
	int settling;
	vdec *vd;
	vtex vt;
	GLuint prog, ext_prog;
	double dur;
	int seg;
	double w0, T0, D, T_end, settle_at, T_pause;
	struct AVFrame *pending, *cur;
	double pending_T, cur_T;
	int have_pending, have_cur;
	int loops;
	int frames;
	int audio;
	float volume;
	int tfd;
} V = { .tfd = -1 };

static double now_s(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static char *dup_or_null(const char *s) {
	return s && *s ? strdup(s) : NULL;
}

static void req_free(struct req *r) {
	if (!r) return;
	free(r->path);
	free(r->output);
	free(r->shader);
	for (int i = 0; i < r->n_opts; i++) free(r->opt_names[i]);
	free(r);
}

static void push(struct req *r) {
	pthread_mutex_lock(&W.lock);
	if (W.tail) W.tail->next = r;
	else W.head = r;
	W.tail = r;
	pthread_mutex_unlock(&W.lock);
	uint64_t one = 1;
	if (W.efd >= 0) (void)!write(W.efd, &one, sizeof one);
}

static struct req *pop(void) {
	pthread_mutex_lock(&W.lock);
	struct req *r = W.head;
	if (r) {
		W.head = r->next;
		if (!W.head) W.tail = NULL;
		r->next = NULL;
	}
	pthread_mutex_unlock(&W.lock);
	return r;
}

void wr_apply(const wr_request *in) {
	if (!in->path || !*in->path) return;
	struct req *r = calloc(1, sizeof *r);
	if (!r) return;
	r->kind = 1;
	r->path = strdup(in->path);
	r->output = dup_or_null(in->output);
	r->shader = in->shader ? strdup(in->shader) : NULL;
	r->duration_ms = in->duration_ms;
	memcpy(r->bezier, in->bezier, sizeof r->bezier);
	r->ink_at = in->ink_at;
	r->band = in->band;
	r->n_opts = in->n_opts > WR_MAX_OPTS ? WR_MAX_OPTS : in->n_opts;
	for (int i = 0; i < r->n_opts; i++) {
		r->opt_names[i] = strdup(in->opt_names[i]);
		r->opt_vals[i] = in->opt_vals[i];
	}
	r->loop = in->loop;
	r->still = in->still;
	r->settle_ms = in->settle_ms;
	r->curve = in->curve;
	r->audio = in->audio;
	r->volume = in->volume;
	r->play = 1;
	push(r);
}

static void command(int kind, double value) {
	struct req *r = calloc(1, sizeof *r);
	if (!r) return;
	r->kind = kind;
	r->still = value;
	push(r);
}

void wr_play(void) { command(3, 0); }
void wr_settle(void) { command(4, 0); }
void wr_pause(int paused) { command(5, paused); }
void wr_still(double seconds) { command(6, seconds); }

void wr_band(int band) {
	struct req *r = calloc(1, sizeof *r);
	if (!r) return;
	r->kind = 2;
	r->band = band;
	push(r);
}

static void emit(int kind, const char *output, const char *path, double luma) {
	if (W.event) W.event(W.ctx, kind, output, path ? path : "", luma);
}

static int buf_w(struct out *o) {
	return (o->lw * o->scale120 + 60) / 120;
}

static int buf_h(struct out *o) {
	return (o->lh * o->scale120 + 60) / 120;
}

static void shm_free(struct shm *s) {
	if (s->buf) wl_buffer_destroy(s->buf);
	if (s->data) munmap(s->data, s->size);
	memset(s, 0, sizeof *s);
}

static int shm_alloc(struct shm *s, int w, int h) {
	memset(s, 0, sizeof *s);
	size_t size = (size_t)w * h * 4;
	int fd = memfd_create("yudae-wallpaper", MFD_CLOEXEC);
	if (fd < 0) return -1;
	if (ftruncate(fd, (off_t)size) != 0) {
		close(fd);
		return -1;
	}
	uint8_t *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) {
		close(fd);
		return -1;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(W.shm, fd, (int32_t)size);
	s->buf = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_XBGR8888);
	wl_shm_pool_destroy(pool);
	close(fd);
	s->data = data;
	s->size = size;
	s->w = w;
	s->h = h;
	return 0;
}

static void present_shm(struct out *o, struct shm *s) {
	wl_surface_attach(o->surf, s->buf, 0, 0);
	wl_surface_damage_buffer(o->surf, 0, 0, INT32_MAX, INT32_MAX);
	wl_surface_commit(o->surf);
	count(&S.commits);
}

static const char *vert_src =
	"#version 300 es\n"
	"uniform float flip;\n"
	"out vec2 uv;\n"
	"void main() {\n"
	"  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2)) * 2.0 - 1.0;\n"
	"  uv = vec2((p.x + 1.0) * 0.5, flip > 0.0 ? (p.y + 1.0) * 0.5 : (1.0 - p.y) * 0.5);\n"
	"  gl_Position = vec4(p, 0.0, 1.0);\n"
	"}\n";

static const char *cover_src =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D img;\n"
	"uniform vec2 off;\n"
	"uniform vec2 scl;\n"
	"in vec2 uv;\n"
	"out vec4 color;\n"
	"void main() { color = vec4(texture(img, off + uv * scl).rgb, 1.0); }\n";

static const char *trans_head =
	"#version 300 es\n"
	"precision highp float;\n"
	"uniform sampler2D old;\n"
	"uniform sampler2D new;\n"
	"uniform float progress;\n"
	"uniform vec2 resolution;\n"
	"uniform float time;\n"
	"in vec2 uv;\n"
	"out vec4 color;\n"
	"#line 1\n";

static const char *fade_src = "void main() { color = vec4(mix(texture(old, uv).rgb, texture(new, uv).rgb, progress), 1.0); }\n";

static GLuint compile(GLenum type, const char *a, const char *b) {
	GLuint sh = glCreateShader(type);
	const char *srcs[2] = { a, b ? b : "" };
	glShaderSource(sh, 2, srcs, NULL);
	glCompileShader(sh);
	GLint ok = 0;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetShaderInfoLog(sh, sizeof log, NULL, log);
		LOG("shader: %s\n", log);
		glDeleteShader(sh);
		return 0;
	}
	return sh;
}

static GLuint program(const char *frag_a, const char *frag_b) {
	GLuint vs = compile(GL_VERTEX_SHADER, vert_src, NULL);
	GLuint fs = compile(GL_FRAGMENT_SHADER, frag_a, frag_b);
	if (!vs || !fs) {
		if (vs) glDeleteShader(vs);
		if (fs) glDeleteShader(fs);
		return 0;
	}
	GLuint p = glCreateProgram();
	glAttachShader(p, vs);
	glAttachShader(p, fs);
	glLinkProgram(p);
	glDeleteShader(vs);
	glDeleteShader(fs);
	GLint ok = 0;
	glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok) {
		glDeleteProgram(p);
		return 0;
	}
	return p;
}

static int gl_up(void) {
	if (W.ctxgl != EGL_NO_CONTEXT) return 0;
	PFNEGLGETPLATFORMDISPLAYEXTPROC get = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	W.egl = get ? get(EGL_PLATFORM_WAYLAND_KHR, W.dpy, NULL) : eglGetDisplay((EGLNativeDisplayType)W.dpy);
	if (W.egl == EGL_NO_DISPLAY || !eglInitialize(W.egl, NULL, NULL)) {
		LOG("egl init failed\n");
		return -1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	const EGLint attrs[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_NONE,
	};
	EGLint n = 0;
	if (!eglChooseConfig(W.egl, attrs, &W.cfg, 1, &n) || n < 1) {
		LOG("no egl config\n");
		eglTerminate(W.egl);
		return -1;
	}
	const EGLint cattrs[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
	W.ctxgl = eglCreateContext(W.egl, W.cfg, EGL_NO_CONTEXT, cattrs);
	if (W.ctxgl == EGL_NO_CONTEXT || !eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl)) {
		LOG("no gl context\n");
		if (W.ctxgl != EGL_NO_CONTEXT) eglDestroyContext(W.egl, W.ctxgl);
		W.ctxgl = EGL_NO_CONTEXT;
		eglTerminate(W.egl);
		return -1;
	}
	W.cover_prog = program(cover_src, NULL);
	glGenFramebuffers(1, &W.fbo);
	return W.cover_prog ? 0 : -1;
}

static void gl_down(void) {
	if (W.ctxgl == EGL_NO_CONTEXT) return;
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (o->old_tex) glDeleteTextures(1, &o->old_tex);
		if (o->new_tex) glDeleteTextures(1, &o->new_tex);
		o->old_tex = o->new_tex = 0;
	}
	if (W.cover_prog) glDeleteProgram(W.cover_prog);
	if (W.trans_prog) glDeleteProgram(W.trans_prog);
	if (W.fbo) glDeleteFramebuffers(1, &W.fbo);
	W.cover_prog = W.trans_prog = W.fbo = 0;
	if (V.prog) glDeleteProgram(V.prog);
	if (V.ext_prog) glDeleteProgram(V.ext_prog);
	V.prog = V.ext_prog = 0;
	eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(W.egl, W.ctxgl);
	W.ctxgl = EGL_NO_CONTEXT;
	eglTerminate(W.egl);
	eglReleaseThread();
	W.egl = EGL_NO_DISPLAY;
}

static GLuint texture(int w, int h, const void *px, int mip) {
	GLuint t;
	glGenTextures(1, &t);
	glBindTexture(GL_TEXTURE_2D, t);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, mip ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
	if (mip) glGenerateMipmap(GL_TEXTURE_2D);
	return t;
}

static void downscale_fit(wr_image *img, int max) {
	while (img->w > max || img->h > max) {
		int w = img->w / 2, h = img->h / 2;
		uint8_t *px = malloc((size_t)w * h * 4);
		if (!px) return;
		for (int y = 0; y < h; y++)
			for (int x = 0; x < w; x++)
				for (int c = 0; c < 4; c++) {
					const uint8_t *s = img->px + ((size_t)(2 * y) * img->w + 2 * x) * 4 + c;
					px[((size_t)y * w + x) * 4 + c] = (uint8_t)((s[0] + s[4] + s[img->w * 4] + s[img->w * 4 + 4] + 2) / 4);
				}
		free(img->px);
		img->px = px;
		img->w = w;
		img->h = h;
	}
}

static int render_cover(GLuint img_tex, int iw, int ih, struct out *o, GLuint *keep_tex) {
	int bw = buf_w(o), bh = buf_h(o);
	GLuint target = texture(bw, bh, NULL, 0);
	glBindFramebuffer(GL_FRAMEBUFFER, W.fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		glDeleteTextures(1, &target);
		return -1;
	}
	glViewport(0, 0, bw, bh);
	glUseProgram(W.cover_prog);
	float off[2], scl[2];
	wr_cover(iw, ih, bw, bh, off, scl);
	glUniform2fv(glGetUniformLocation(W.cover_prog, "off"), 1, off);
	glUniform2fv(glGetUniformLocation(W.cover_prog, "scl"), 1, scl);
	glUniform1f(glGetUniformLocation(W.cover_prog, "flip"), 1.0f);
	glUniform1i(glGetUniformLocation(W.cover_prog, "img"), 0);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, img_tex);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	shm_free(&o->next);
	if (shm_alloc(&o->next, bw, bh) != 0) {
		glDeleteTextures(1, &target);
		glBindFramebuffer(GL_FRAMEBUFFER, 0);
		return -1;
	}
	glPixelStorei(GL_PACK_ALIGNMENT, 4);
	glReadPixels(0, 0, bw, bh, GL_RGBA, GL_UNSIGNED_BYTE, o->next.data);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	if (keep_tex) *keep_tex = target;
	else glDeleteTextures(1, &target);
	return 0;
}

static double measure(struct out *o, struct shm *s) {
	int rows = wr_band_rows(W.band, o->scale120, s->h);
	if (rows <= 0 || !s->data) return -1;
	return wr_band_luma(s->data, s->w, rows);
}

static void stop_anim(struct out *o) {
	if (o->cb) wl_callback_destroy(o->cb);
	o->cb = NULL;
	if (o->es != EGL_NO_SURFACE) {
		eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl);
		eglDestroySurface(W.egl, o->es);
	}
	o->es = EGL_NO_SURFACE;
	if (o->ew) wl_egl_window_destroy(o->ew);
	o->ew = NULL;
	if (o->old_tex) glDeleteTextures(1, &o->old_tex);
	if (o->new_tex) glDeleteTextures(1, &o->new_tex);
	o->old_tex = o->new_tex = 0;
	o->animating = 0;
}

static void land(struct out *o) {
	present_shm(o, &o->next);
	if (o->animating) {
		LOG("%s transition frames=%d ms=%.0f ink=+%.0fms\n", o->name, o->frames, (now_s() - o->t0) * 1000, (o->ink_t - o->t0) * 1000);
		stop_anim(o);
	}
	shm_free(&o->shown);
	o->shown = o->next;
	memset(&o->next, 0, sizeof o->next);
	snprintf(o->path, sizeof o->path, "%s", o->next_path);
	o->luma = o->next_luma;
	if (!o->ink_fired && o->luma >= 0) emit(WR_EVENT_INK, o->name, o->path, o->luma);
	o->ink_fired = 1;
	emit(WR_EVENT_SHOWN, o->name, o->path, o->luma);
}

static int any_animating(void) {
	struct out *o;
	wl_list_for_each(o, &W.outs, link) if (o->animating) return 1;
	return 0;
}

static int video_active(void);
static void video_start(void);
static void video_draw(struct out *o);

static void maybe_idle(void) {
	if (any_animating()) return;
	if (W.trans_req) {
		req_free(W.trans_req);
		W.trans_req = NULL;
	}
	video_start();
	if (video_active()) return;
	gl_down();
}

static void frame_done(void *data, struct wl_callback *cb, uint32_t t);
static const struct wl_callback_listener frame_listener = { frame_done };

static void draw_frame(struct out *o) {
	struct req *r = o->anim;
	double elapsed = now_s() - o->t0;
	double lin = r->duration_ms > 0 ? elapsed * 1000.0 / r->duration_ms : 1;
	if (lin >= 1) {
		land(o);
		maybe_idle();
		return;
	}
	double p = wr_bezier(r->bezier, lin);
	eglMakeCurrent(W.egl, o->es, o->es, W.ctxgl);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glViewport(0, 0, o->next.w, o->next.h);
	glUseProgram(W.trans_prog);
	glUniform1f(glGetUniformLocation(W.trans_prog, "flip"), 0.0f);
	glUniform1f(glGetUniformLocation(W.trans_prog, "progress"), (float)p);
	glUniform1f(glGetUniformLocation(W.trans_prog, "time"), (float)elapsed);
	glUniform2f(glGetUniformLocation(W.trans_prog, "resolution"), (float)o->next.w, (float)o->next.h);
	for (int i = 0; i < r->n_opts; i++) glUniform1f(glGetUniformLocation(W.trans_prog, r->opt_names[i]), r->opt_vals[i]);
	glUniform1i(glGetUniformLocation(W.trans_prog, "old"), 0);
	glUniform1i(glGetUniformLocation(W.trans_prog, "new"), 1);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, o->old_tex);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, o->new_tex);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	o->cb = wl_surface_frame(o->surf);
	wl_callback_add_listener(o->cb, &frame_listener, o);
	eglSwapBuffers(W.egl, o->es);
	count(&S.commits);
	o->frames++;
	if (!o->ink_fired && p >= r->ink_at) {
		o->ink_fired = 1;
		o->ink_t = now_s();
		if (o->next_luma >= 0) emit(WR_EVENT_INK, o->name, o->next_path, o->next_luma);
	}
}

static void frame_done(void *data, struct wl_callback *cb, uint32_t t) {
	(void)t;
	struct out *o = data;
	wl_callback_destroy(cb);
	o->cb = NULL;
	if (o->animating) draw_frame(o);
	else if (o->video && o->vdirty) video_draw(o);
}


static GLuint upload_image(wr_image *img, int *iw, int *ih);
static int render_cover(GLuint img_tex, int iw, int ih, struct out *o, GLuint *keep_tex);
static double measure(struct out *o, struct shm *s);

double wr_settle_pos(double u, double curve) {
	if (u <= 0) return 0;
	if (u >= 1) return 1;
	return 1 - pow(1 - u, curve);
}

double wr_settle_target(double now, double still, double dur, double travel) {
	double want = now + travel;
	if (dur <= 0) return still >= want ? still : want;
	double n = ceil((want - still) / dur - 1e-9);
	if (n < 0) n = 0;
	return still + n * dur;
}


static double travel(void) {
	return V.settle / V.curve;
}

static double timeline(double w) {
	double u = V.D > 0 ? (w - V.w0) / V.D : 1;
	switch (V.seg) {
	case SEG_DOWN:
		return V.T0 + travel() * wr_settle_pos(u, V.curve);
	case SEG_UP:
		if (u >= 1) return V.T0 + travel() + (w - V.w0 - V.D);
		return V.T0 + travel() * (u <= 0 ? 0 : pow(u, V.curve));
	default:
		return V.T0 + (w - V.w0);
	}
}

static double wall_of(double T) {
	double x = (T - V.T0) / travel();
	switch (V.seg) {
	case SEG_DOWN:
		if (x >= 1) return V.w0 + V.D;
		return V.w0 + V.D * (1 - pow(1 - (x < 0 ? 0 : x), 1 / V.curve));
	case SEG_UP:
		if (x >= 1) return V.w0 + V.D + (T - V.T0 - travel());
		return V.w0 + V.D * pow(x < 0 ? 0 : x, 1 / V.curve);
	default:
		return V.w0 + (T - V.T0);
	}
}

static void arm(double at) {
	struct itimerspec it = { 0 };
	if (at > 0) {
		if (at < 1e-6) at = 1e-6;
		it.it_value.tv_sec = (time_t)at;
		it.it_value.tv_nsec = (long)((at - (double)(time_t)at) * 1e9);
		if (it.it_value.tv_sec == 0 && it.it_value.tv_nsec == 0) it.it_value.tv_nsec = 1;
	}
	if (V.tfd >= 0) timerfd_settime(V.tfd, TFD_TIMER_ABSTIME, &it, NULL);
}

static int decode_pending(void) {
	for (int guard = 0; guard < 3;) {
		struct AVFrame *f;
		double pts;
		int r = vd_next(V.vd, &f, &pts);
		if (r == 0) {
			count(&S.decoded);
			av_frame_unref(V.pending);
			av_frame_ref(V.pending, f);
			V.pending_T = V.loops * V.dur + pts;
			V.have_pending = 1;
			return 0;
		}
		if (r != 1 || V.dur <= 0) break;
		vd_seek(V.vd, 0);
		V.loops++;
		guard++;
	}
	V.have_pending = 0;
	return -1;
}

static int video_open(double from) {
	if (!V.vd) {
		V.vd = vd_open(V.path, 1);
		if (!V.vd) {
			LOG("cannot open video %s\n", V.path);
			return -1;
		}
		V.dur = vd_duration(V.vd);
		if (!V.pending) V.pending = av_frame_alloc();
		if (!V.cur) V.cur = av_frame_alloc();
	}
	V.loops = 0;
	V.have_pending = V.have_cur = 0;
	if (from > 0) vd_seek(V.vd, from);
	else if (V.frames) vd_seek(V.vd, 0);
	V.frames = 0;
	while (decode_pending() == 0 && V.pending_T < from - 0.5 / vd_fps(V.vd)) {
	}
	return V.have_pending ? 0 : -1;
}

static void video_programs(void) {
	if (!V.prog) V.prog = program(video_frag_src, NULL);
	if (!V.ext_prog) V.ext_prog = program(video_ext_src, NULL);
}

static void video_draw_bound(int bw, int bh, float flip) {
	GLuint prog = V.vt.planes == 0 ? V.ext_prog : V.prog;
	glViewport(0, 0, bw, bh);
	glUseProgram(prog);
	float off[2], scl[2];
	wr_cover(V.vt.w, V.vt.h, bw, bh, off, scl);
	glUniform1f(glGetUniformLocation(prog, "flip"), flip);
	glUniform2fv(glGetUniformLocation(prog, "coff"), 1, off);
	glUniform2fv(glGetUniformLocation(prog, "cscl"), 1, scl);
	vt_bind(&V.vt, prog);
	glDrawArrays(GL_TRIANGLES, 0, 3);
}

static void video_draw(struct out *o) {
	if (o->es == EGL_NO_SURFACE || !V.have_cur) return;
	eglMakeCurrent(W.egl, o->es, o->es, W.ctxgl);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	video_draw_bound(buf_w(o), buf_h(o), 0.0f);
	o->cb = wl_surface_frame(o->surf);
	wl_callback_add_listener(o->cb, &frame_listener, o);
	eglSwapBuffers(W.egl, o->es);
	count(&S.commits);
	count(&S.presented);
	o->vdirty = 0;
	eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl);
}

static int video_snapshot(struct out *o, struct shm *dst) {
	if (!V.have_cur) return -1;
	int bw = buf_w(o), bh = buf_h(o);
	GLuint target = texture(bw, bh, NULL, 0);
	glBindFramebuffer(GL_FRAMEBUFFER, W.fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
	video_draw_bound(bw, bh, 1.0f);
	shm_free(dst);
	int rc = shm_alloc(dst, bw, bh);
	if (rc == 0) glReadPixels(0, 0, bw, bh, GL_RGBA, GL_UNSIGNED_BYTE, dst->data);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glDeleteTextures(1, &target);
	return rc;
}

static void video_surface(struct out *o) {
	if (o->es != EGL_NO_SURFACE) return;
	o->ew = wl_egl_window_create(o->surf, buf_w(o), buf_h(o));
	o->es = eglCreateWindowSurface(W.egl, W.cfg, (EGLNativeWindowType)o->ew, NULL);
	if (o->es == EGL_NO_SURFACE) return;
	eglMakeCurrent(W.egl, o->es, o->es, W.ctxgl);
	eglSwapInterval(W.egl, 0);
	eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl);
}

static void video_unsurface(struct out *o) {
	if (o->cb) wl_callback_destroy(o->cb);
	o->cb = NULL;
	if (o->es != EGL_NO_SURFACE) {
		eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl);
		eglDestroySurface(W.egl, o->es);
	}
	o->es = EGL_NO_SURFACE;
	if (o->ew) wl_egl_window_destroy(o->ew);
	o->ew = NULL;
	o->vdirty = 0;
}

static void video_present(void) {
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (!o->video) continue;
		if (o->cb) {
			if (o->vdirty) count(&S.dropped);
			o->vdirty = 1;
		} else {
			video_draw(o);
		}
	}
}

static void video_plan_settle(double from) {
	V.T_end = wr_settle_target(from, V.still, V.dur, travel());
	V.settle_at = V.T_end - travel();
	V.settling = 1;
}

static void video_land_still(void);

static void video_audio(double from, double fade) {
	if (!wr_audio_opens(V.audio, V.volume)) return;
	if (au_start(V.path, from, V.volume, fade) != 0) LOG("no audio in %s\n", V.path);
}

static void video_tick(void) {
	if (V.mode != V_PLAY || V.paused) return;
	double now = now_s();
	if (V.settling && V.seg == SEG_LINEAR && timeline(now) >= V.settle_at) {
		V.w0 = wall_of(V.settle_at);
		V.T0 = V.settle_at;
		V.D = V.settle;
		V.seg = SEG_DOWN;
		au_fade(0, V.settle);
	}
	if (V.seg == SEG_UP && now >= V.w0 + V.D) {
		V.T0 += travel();
		V.w0 += V.D;
		V.seg = SEG_LINEAR;
	}
	double T = V.seg == SEG_DOWN && now >= V.w0 + V.D ? V.T_end : timeline(now);
	int got = 0;
	while (V.have_pending && V.pending_T <= T + 1e-4) {
		if (got) count(&S.dropped);
		av_frame_unref(V.cur);
		av_frame_move_ref(V.cur, V.pending);
		V.cur_T = V.pending_T;
		V.have_cur = 1;
		got = 1;
		if (decode_pending() != 0) break;
	}
	if (got) {
		if (vt_upload(&V.vt, W.egl, V.cur) == 0) {
			V.frames++;
			video_present();
		}
	}
	if (V.seg == SEG_DOWN && now >= V.w0 + V.D) {
		video_land_still();
		return;
	}
	double next = 0;
	if (V.have_pending) next = wall_of(V.pending_T);
	if (V.seg == SEG_DOWN && (next == 0 || next > V.w0 + V.D)) next = V.w0 + V.D;
	if (V.settling && V.seg == SEG_LINEAR) {
		double at = wall_of(V.settle_at);
		if (next == 0 || at < next) next = at;
	}
	if (V.seg == SEG_UP && (next == 0 || next > V.w0 + V.D)) next = V.w0 + V.D;
	arm(next);
}

static void video_release_decoder(void) {
	if (V.pending) av_frame_free(&V.pending);
	if (V.cur) av_frame_free(&V.cur);
	vd_close(V.vd);
	V.vd = NULL;
	V.have_pending = V.have_cur = 0;
}

static void video_land_still(void) {
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (!o->video) continue;
		present_shm(o, &o->still);
		video_unsurface(o);
		shm_free(&o->shown);
		o->shown = o->still;
		memset(&o->still, 0, sizeof o->still);
		emit(WR_EVENT_SHOWN, o->name, V.path, o->luma);
	}
	LOG("video settled on %.3fs after %d frames\n", V.cur_T - V.loops * V.dur, V.frames);
	pthread_mutex_lock(&W.lock);
	S.settles++;
	S.landed_error = fabs(V.cur_T - V.T_end);
	pthread_mutex_unlock(&W.lock);
	vt_free(&V.vt, W.egl);
	video_release_decoder();
	au_stop();
	arm(0);
	V.mode = V_STILL;
	V.settling = 0;
	V.seg = SEG_LINEAR;
	maybe_idle();
}

static void maybe_idle(void);

static void video_begin(double from, int seg) {
	if (gl_up() != 0) return;
	video_programs();
	if (video_open(from) != 0) {
		V.mode = V_OFF;
		maybe_idle();
		return;
	}
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (!o->video) continue;
		if (!o->still.data) {
			o->still = o->shown;
			memset(&o->shown, 0, sizeof o->shown);
		}
		video_surface(o);
	}
	V.mode = V_PLAY;
	V.seg = seg;
	V.w0 = now_s();
	V.T0 = from;
	V.D = V.settle;
	V.settling = 0;
	if (!V.loop) video_plan_settle(seg == SEG_UP ? from + V.dur - travel() : from);
	video_audio(from, seg == SEG_UP ? V.settle : 0.3);
	LOG("video %s from %.3fs hw=%d dur=%.2fs\n", V.path, from, vd_hw(V.vd), V.dur);
	video_tick();
}

static void video_start(void) {
	if (V.mode != V_PENDING || V.paused) return;
	video_begin(0, SEG_LINEAR);
}

static void video_stop(void) {
	if (V.mode == V_OFF) return;
	struct out *o;
	if (V.mode == V_PLAY && !V.paused && W.ctxgl != EGL_NO_CONTEXT) {
		wl_list_for_each(o, &W.outs, link) {
			if (!o->video) continue;
			if (video_snapshot(o, &o->shown) == 0) present_shm(o, &o->shown);
		}
	}
	wl_list_for_each(o, &W.outs, link) {
		if (!o->video) continue;
		video_unsurface(o);
		shm_free(&o->still);
		o->video = 0;
	}
	if (W.ctxgl != EGL_NO_CONTEXT) vt_free(&V.vt, W.egl);
	video_release_decoder();
	au_stop();
	arm(0);
	V.mode = V_OFF;
	V.settling = 0;
}

static void video_pause(int paused) {
	if (paused == V.paused) return;
	V.paused = paused;
	struct out *o;
	if (paused) {
		if (V.mode != V_PLAY) return;
		V.T_pause = timeline(now_s());
		wl_list_for_each(o, &W.outs, link) {
			if (!o->video) continue;
			if (video_snapshot(o, &o->shown) == 0) present_shm(o, &o->shown);
			video_unsurface(o);
		}
		vt_free(&V.vt, W.egl);
		au_pause(1);
		arm(0);
		LOG("video paused at %.3fs\n", V.T_pause);
		maybe_idle();
		return;
	}
	if (V.mode == V_PENDING) {
		video_start();
		return;
	}
	if (V.mode != V_PLAY || gl_up() != 0) return;
	video_programs();
	wl_list_for_each(o, &W.outs, link) if (o->video) video_surface(o);
	V.seg = SEG_LINEAR;
	V.w0 = now_s();
	V.T0 = V.T_pause;
	if (V.settling) video_plan_settle(V.T_pause);
	if (V.have_cur && vt_upload(&V.vt, W.egl, V.cur) == 0) video_present();
	au_pause(0);
	LOG("video resumed at %.3fs\n", V.T_pause);
	video_tick();
}

static void video_play(void) {
	if (V.paused) return;
	if (V.mode == V_STILL) {
		video_begin(V.still, SEG_UP);
	} else if (V.mode == V_PLAY && V.settling) {
		V.settling = 0;
		au_fade(1, 0.3);
		if (V.seg == SEG_DOWN) {
			double T = timeline(now_s());
			V.seg = SEG_LINEAR;
			V.T0 = T;
			V.w0 = now_s();
		}
		video_tick();
	}
}

static void video_settle(void) {
	if (V.mode != V_PLAY || V.paused || V.settling) return;
	video_plan_settle(timeline(now_s()));
	video_tick();
}

static void video_still(double seconds) {
	if (V.mode == V_OFF || seconds < 0) return;
	V.still = seconds;
	wr_image img;
	if (wr_decode_at(V.path, seconds, &img) != 0) return;
	int up = W.ctxgl != EGL_NO_CONTEXT;
	if (!up && gl_up() != 0) {
		wr_image_free(&img);
		return;
	}
	int iw, ih;
	GLuint tex = upload_image(&img, &iw, &ih);
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (!o->video) continue;
		if (render_cover(tex, iw, ih, o, NULL) != 0) continue;
		struct shm *slot = V.mode == V_STILL ? &o->shown : &o->still;
		shm_free(slot);
		*slot = o->next;
		memset(&o->next, 0, sizeof o->next);
		o->luma = o->still_luma = measure(o, slot);
		if (o->luma >= 0) emit(WR_EVENT_INK, o->name, V.path, o->luma);
		if (V.mode == V_STILL) present_shm(o, slot);
	}
	glDeleteTextures(1, &tex);
	if (V.settling) video_plan_settle(timeline(now_s()));
	maybe_idle();
}

static int video_active(void) {
	return V.mode == V_PLAY && !V.paused;
}

static int wants(struct req *r, struct out *o) {
	return !r->output || !strcmp(r->output, o->name);
}

static GLuint upload_image(wr_image *img, int *iw, int *ih) {
	GLint max = 4096;
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max);
	downscale_fit(img, max);
	GLuint t = texture(img->w, img->h, img->px, 1);
	*iw = img->w;
	*ih = img->h;
	wr_image_free(img);
	return t;
}

static void apply(struct req *r) {
	struct out *o;
	int mw = 0, mh = 0, count = 0;
	int video = wr_is_video(r->path);
	wl_list_for_each(o, &W.outs, link) if (o->animating) land(o);
	if (W.trans_req) req_free(W.trans_req);
	W.trans_req = NULL;
	if (V.mode != V_OFF && (!r->output || video)) {
		if (V.mode == V_PLAY && !V.paused) gl_up();
		video_stop();
	}
	if (video) {
		free(r->output);
		r->output = NULL;
	}
	wl_list_for_each(o, &W.outs, link) {
		if (!wants(r, o) || !o->configured) continue;
		if (buf_w(o) > mw) mw = buf_w(o);
		if (buf_h(o) > mh) mh = buf_h(o);
		count++;
	}
	if (r->band > 0) W.band = r->band;
	if (!r->output) {
		free(W.last_path);
		W.last_path = strdup(r->path);
	}
	if (!count) {
		req_free(r);
		maybe_idle();
		return;
	}
	double t0 = now_s();
	wr_image img = { 0 }, still_img = { 0 };
	double still = r->still > 0 ? r->still : 0;
	int rc = video ? wr_decode_at(r->path, 0, &img) : wr_decode(r->path, mw, mh, &img);
	if (rc == 0 && video && still > 0 && wr_decode_at(r->path, still, &still_img) != 0) rc = -1;
	if (rc != 0) {
		LOG("cannot decode %s\n", r->path);
		wr_image_free(&img);
		req_free(r);
		maybe_idle();
		return;
	}
	double t1 = now_s();
	if (gl_up() != 0) {
		wr_image_free(&img);
		wr_image_free(&still_img);
		req_free(r);
		return;
	}
	int iw, ih, sw = 0, sh = 0;
	GLuint img_tex = upload_image(&img, &iw, &ih);
	GLuint still_tex = still_img.px ? upload_image(&still_img, &sw, &sh) : 0;
	int animate = r->shader && *r->shader && r->duration_ms > 0;
	if (animate) {
		if (W.trans_prog) glDeleteProgram(W.trans_prog);
		W.trans_prog = program(trans_head, r->shader);
		if (!W.trans_prog) animate = 0;
	}
	if (video) {
		snprintf(V.path, sizeof V.path, "%s", r->path);
		V.loop = r->loop;
		V.still = still;
		V.settle = (r->settle_ms > 0 ? r->settle_ms : 1200) / 1000.0;
		V.curve = r->curve >= 1 ? r->curve : 3;
		V.audio = r->audio;
		V.volume = r->volume;
		V.mode = V_PENDING;
		V.settling = 0;
	}
	wl_list_for_each(o, &W.outs, link) {
		if (!wants(r, o) || !o->configured) continue;
		int fade = animate && o->shown.data;
		o->video = video;
		if (video) {
			if (still_tex) {
				if (render_cover(still_tex, sw, sh, o, NULL) != 0) continue;
				shm_free(&o->still);
				o->still = o->next;
				memset(&o->next, 0, sizeof o->next);
			}
		}
		if (render_cover(img_tex, iw, ih, o, fade ? &o->new_tex : NULL) != 0) continue;
		if (video && !still_tex) {
			shm_free(&o->still);
			if (shm_alloc(&o->still, o->next.w, o->next.h) == 0) memcpy(o->still.data, o->next.data, o->next.size);
		}
		snprintf(o->next_path, sizeof o->next_path, "%s", r->path);
		o->next_luma = measure(o, video ? &o->still : &o->next);
		o->still_luma = o->next_luma;
		o->ink_fired = 0;
		if (!fade) {
			land(o);
			continue;
		}
		o->old_tex = texture(o->shown.w, o->shown.h, o->shown.data, 0);
		o->ew = wl_egl_window_create(o->surf, o->next.w, o->next.h);
		o->es = eglCreateWindowSurface(W.egl, W.cfg, (EGLNativeWindowType)o->ew, NULL);
		if (o->es == EGL_NO_SURFACE) {
			o->animating = 1;
			land(o);
			continue;
		}
		eglMakeCurrent(W.egl, o->es, o->es, W.ctxgl);
		eglSwapInterval(W.egl, 0);
		o->animating = 1;
		o->anim = r;
		o->frames = 0;
		o->t0 = o->ink_t = now_s();
		draw_frame(o);
	}
	eglMakeCurrent(W.egl, EGL_NO_SURFACE, EGL_NO_SURFACE, W.ctxgl);
	glDeleteTextures(1, &img_tex);
	if (still_tex) glDeleteTextures(1, &still_tex);
	LOG("apply %s decode=%.1fms total=%.1fms\n", r->path, (t1 - t0) * 1000, (now_s() - t0) * 1000);
	if (any_animating()) {
		W.trans_req = r;
		return;
	}
	req_free(r);
	maybe_idle();
}

static void rebanded(int band) {
	W.band = band;
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		struct shm *src = o->video && o->still.data ? &o->still : &o->shown;
		if (!src->data) continue;
		o->luma = measure(o, src);
		if (o->luma >= 0) emit(WR_EVENT_INK, o->name, o->path, o->luma);
	}
}

static void refresh_dirty(void) {
	struct out *o;
	wl_list_for_each(o, &W.outs, link) {
		if (!o->dirty || !o->configured) continue;
		o->dirty = 0;
		const char *path = o->path[0] ? o->path : W.last_path;
		if (!path) continue;
		struct req *r = calloc(1, sizeof *r);
		if (!r) continue;
		r->kind = 1;
		r->path = strdup(path);
		r->output = V.mode != V_OFF && !strcmp(path, V.path) ? NULL : strdup(o->name);
		r->loop = V.loop;
		r->still = V.still;
		r->settle_ms = (int)(V.settle * 1000);
		r->curve = (float)V.curve;
		apply(r);
	}
}

static void layer_configure(void *data, struct zwlr_layer_surface_v1 *l, uint32_t serial, uint32_t w, uint32_t h) {
	struct out *o = data;
	zwlr_layer_surface_v1_ack_configure(l, serial);
	if ((int)w != o->lw || (int)h != o->lh || !o->configured) o->dirty = 1;
	o->lw = (int)w;
	o->lh = (int)h;
	o->configured = 1;
	if (o->vp) wp_viewport_set_destination(o->vp, o->lw, o->lh);
}

static void layer_closed(void *data, struct zwlr_layer_surface_v1 *l) {
	(void)l;
	struct out *o = data;
	o->configured = 0;
}

static const struct zwlr_layer_surface_v1_listener layer_listener = { layer_configure, layer_closed };

static void frac_scale(void *data, struct wp_fractional_scale_v1 *f, uint32_t scale) {
	(void)f;
	struct out *o = data;
	if ((int)scale != o->scale120) o->dirty = 1;
	o->scale120 = (int)scale;
}

static const struct wp_fractional_scale_v1_listener frac_listener = { frac_scale };

static void out_geometry(void *d, struct wl_output *w, int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp, const char *mk, const char *md, int32_t tr) {
	(void)d; (void)w; (void)x; (void)y; (void)pw; (void)ph; (void)sp; (void)mk; (void)md; (void)tr;
}

static void out_mode(void *d, struct wl_output *w, uint32_t f, int32_t wd, int32_t ht, int32_t r) {
	(void)d; (void)w; (void)f; (void)wd; (void)ht; (void)r;
}

static void make_surface(struct out *o);

static void out_done(void *data, struct wl_output *w) {
	(void)w;
	struct out *o = data;
	if (!o->surf && o->name[0] && W.layer_shell) make_surface(o);
}

static void out_scale(void *data, struct wl_output *w, int32_t s) {
	(void)w;
	struct out *o = data;
	o->int_scale = s;
	if (!o->frac) o->scale120 = s * 120;
}

static void out_name(void *data, struct wl_output *w, const char *name) {
	(void)w;
	struct out *o = data;
	snprintf(o->name, sizeof o->name, "%s", name);
}

static void out_desc(void *d, struct wl_output *w, const char *s) {
	(void)d; (void)w; (void)s;
}

static const struct wl_output_listener out_listener = { out_geometry, out_mode, out_done, out_scale, out_name, out_desc };

static void make_surface(struct out *o) {
	o->surf = wl_compositor_create_surface(W.comp);
	struct wl_region *empty = wl_compositor_create_region(W.comp);
	wl_surface_set_input_region(o->surf, empty);
	wl_region_destroy(empty);
	if (W.viewporter) o->vp = wp_viewporter_get_viewport(W.viewporter, o->surf);
	if (W.frac_mgr) {
		o->frac = wp_fractional_scale_manager_v1_get_fractional_scale(W.frac_mgr, o->surf);
		wp_fractional_scale_v1_add_listener(o->frac, &frac_listener, o);
	}
	if (!o->vp) wl_surface_set_buffer_scale(o->surf, o->int_scale > 0 ? o->int_scale : 1);
	o->layer = zwlr_layer_shell_v1_get_layer_surface(W.layer_shell, o->surf, o->wl, ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "wallpaper");
	zwlr_layer_surface_v1_set_anchor(o->layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
	zwlr_layer_surface_v1_set_exclusive_zone(o->layer, -1);
	zwlr_layer_surface_v1_set_keyboard_interactivity(o->layer, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);
	zwlr_layer_surface_v1_add_listener(o->layer, &layer_listener, o);
	wl_surface_commit(o->surf);
}

static void out_destroy(struct out *o) {
	if (o->animating) stop_anim(o);
	if (o->video) video_unsurface(o);
	shm_free(&o->still);
	shm_free(&o->shown);
	shm_free(&o->next);
	if (o->frac) wp_fractional_scale_v1_destroy(o->frac);
	if (o->vp) wp_viewport_destroy(o->vp);
	if (o->layer) zwlr_layer_surface_v1_destroy(o->layer);
	if (o->surf) wl_surface_destroy(o->surf);
	if (o->wl) wl_output_release(o->wl);
	wl_list_remove(&o->link);
	free(o);
}

static void reg_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
	(void)data;
	if (!strcmp(iface, wl_compositor_interface.name)) {
		W.comp = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
	} else if (!strcmp(iface, wl_shm_interface.name)) {
		W.shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (!strcmp(iface, zwlr_layer_shell_v1_interface.name)) {
		W.layer_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, version < 4 ? version : 4);
	} else if (!strcmp(iface, wp_viewporter_interface.name)) {
		W.viewporter = wl_registry_bind(reg, name, &wp_viewporter_interface, 1);
	} else if (!strcmp(iface, wp_fractional_scale_manager_v1_interface.name)) {
		W.frac_mgr = wl_registry_bind(reg, name, &wp_fractional_scale_manager_v1_interface, 1);
	} else if (!strcmp(iface, wl_output_interface.name) && version >= 4) {
		struct out *o = calloc(1, sizeof *o);
		if (!o) return;
		o->gname = name;
		o->scale120 = 120;
		o->int_scale = 1;
		o->es = EGL_NO_SURFACE;
		o->luma = o->next_luma = -1;
		o->wl = wl_registry_bind(reg, name, &wl_output_interface, 4);
		wl_output_add_listener(o->wl, &out_listener, o);
		wl_list_insert(&W.outs, &o->link);
	}
}

static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
	(void)data;
	(void)reg;
	struct out *o, *tmp;
	wl_list_for_each_safe(o, tmp, &W.outs, link) {
		if (o->gname != name) continue;
		char gone[64];
		snprintf(gone, sizeof gone, "%s", o->name);
		out_destroy(o);
		emit(WR_EVENT_GONE, gone, NULL, -1);
	}
	maybe_idle();
}

static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void disconnect(void) {
	video_stop();
	struct out *o, *tmp;
	wl_list_for_each_safe(o, tmp, &W.outs, link) out_destroy(o);
	if (W.trans_req) req_free(W.trans_req);
	W.trans_req = NULL;
	video_stop();
	gl_down();
	if (W.frac_mgr) wp_fractional_scale_manager_v1_destroy(W.frac_mgr);
	if (W.viewporter) wp_viewporter_destroy(W.viewporter);
	if (W.layer_shell) zwlr_layer_shell_v1_destroy(W.layer_shell);
	if (W.shm) wl_shm_destroy(W.shm);
	if (W.comp) wl_compositor_destroy(W.comp);
	if (W.reg) wl_registry_destroy(W.reg);
	if (W.dpy) wl_display_disconnect(W.dpy);
	W.frac_mgr = NULL;
	W.viewporter = NULL;
	W.layer_shell = NULL;
	W.shm = NULL;
	W.comp = NULL;
	W.reg = NULL;
	W.dpy = NULL;
}

static struct wl_display *connect_any(void) {
	if (getenv("WAYLAND_DISPLAY")) return wl_display_connect(NULL);
	const char *dir = getenv("XDG_RUNTIME_DIR");
	DIR *d = dir ? opendir(dir) : NULL;
	if (!d) return NULL;
	struct wl_display *dpy = NULL;
	struct dirent *e;
	while (!dpy && (e = readdir(d))) {
		if (strncmp(e->d_name, "wayland-", 8) || strchr(e->d_name + 8, '.') || strchr(e->d_name + 8, '-')) continue;
		dpy = wl_display_connect(e->d_name);
	}
	closedir(d);
	return dpy;
}

static int session(void) {
	W.dpy = connect_any();
	if (!W.dpy) return -1;
	wl_list_init(&W.outs);
	W.reg = wl_display_get_registry(W.dpy);
	wl_registry_add_listener(W.reg, &reg_listener, NULL);
	wl_display_roundtrip(W.dpy);
	if (!W.comp || !W.shm || !W.layer_shell) {
		LOG("compositor lacks layer-shell\n");
		disconnect();
		return -1;
	}
	wl_display_roundtrip(W.dpy);
	wl_display_roundtrip(W.dpy);
	if (V.tfd < 0) V.tfd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	struct pollfd fds[3] = { { wl_display_get_fd(W.dpy), POLLIN, 0 }, { W.efd, POLLIN, 0 }, { V.tfd, POLLIN, 0 } };
	for (;;) {
		refresh_dirty();
		struct req *r;
		while ((r = pop())) {
			switch (r->kind) {
			case 1:
				apply(r);
				r = NULL;
				break;
			case 2:
				rebanded(r->band);
				break;
			case 3:
				video_play();
				break;
			case 4:
				video_settle();
				break;
			case 5:
				video_pause(r->still != 0);
				break;
			case 6:
				video_still(r->still);
				break;
			}
			req_free(r);
			refresh_dirty();
		}
		while (wl_display_prepare_read(W.dpy) != 0) wl_display_dispatch_pending(W.dpy);
		if (wl_display_flush(W.dpy) < 0 && errno != EAGAIN) {
			wl_display_cancel_read(W.dpy);
			break;
		}
		if (poll(fds, 3, -1) < 0 && errno != EINTR) {
			wl_display_cancel_read(W.dpy);
			break;
		}
		if (fds[0].revents & POLLIN) {
			if (wl_display_read_events(W.dpy) < 0) break;
		} else {
			wl_display_cancel_read(W.dpy);
		}
		if (fds[0].revents & (POLLERR | POLLHUP)) break;
		if (fds[1].revents & POLLIN) {
			uint64_t v;
			(void)!read(W.efd, &v, sizeof v);
		}
		if (fds[2].revents & POLLIN) {
			uint64_t v;
			(void)!read(V.tfd, &v, sizeof v);
			video_tick();
		}
		if (wl_display_dispatch_pending(W.dpy) < 0) break;
	}
	disconnect();
	return 0;
}

static void *loop(void *arg) {
	(void)arg;
	unsigned wait = 1;
	for (;;) {
		if (session() == 0) wait = 1;
		sleep(wait);
		if (wait < 60) wait *= 2;
		pthread_mutex_lock(&W.lock);
		char *path = W.last_path ? strdup(W.last_path) : NULL;
		pthread_mutex_unlock(&W.lock);
		if (path) {
			wr_request req = { .path = path };
			wr_apply(&req);
			free(path);
		}
	}
	return NULL;
}

int wr_start(void *ctx, wr_event_fn event) {
	if (W.efd >= 0) return 0;
	setenv("__NV_DISABLE_EXPLICIT_SYNC", "1", 0);
	W.ctx = ctx;
	W.event = event;
	W.egl = EGL_NO_DISPLAY;
	W.ctxgl = EGL_NO_CONTEXT;
	W.efd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	if (W.efd < 0) return -1;
	pthread_t t;
	if (pthread_create(&t, NULL, loop, NULL) != 0) return -1;
	pthread_detach(t);
	return 0;
}

struct offscreen {
	EGLDisplay dpy;
	EGLContext ctx;
	struct wl_display *wl;
};

static int offscreen_up(struct offscreen *o, char *err, int len) {
	PFNEGLGETPLATFORMDISPLAYEXTPROC get = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	o->dpy = EGL_NO_DISPLAY;
	o->ctx = EGL_NO_CONTEXT;
	o->wl = getenv("WAYLAND_DISPLAY") ? wl_display_connect(NULL) : NULL;
	if (get && o->wl) {
		o->dpy = get(EGL_PLATFORM_WAYLAND_KHR, o->wl, NULL);
		if (o->dpy != EGL_NO_DISPLAY && !eglInitialize(o->dpy, NULL, NULL)) o->dpy = EGL_NO_DISPLAY;
	}
	if (get && o->dpy == EGL_NO_DISPLAY) {
		PFNEGLQUERYDEVICESEXTPROC query = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
		EGLDeviceEXT devs[8];
		EGLint n = 0;
		if (query && query(8, devs, &n))
			for (int i = 0; i < n && o->dpy == EGL_NO_DISPLAY; i++) {
				o->dpy = get(EGL_PLATFORM_DEVICE_EXT, devs[i], NULL);
				if (o->dpy != EGL_NO_DISPLAY && !eglInitialize(o->dpy, NULL, NULL)) o->dpy = EGL_NO_DISPLAY;
			}
		if (o->dpy == EGL_NO_DISPLAY) {
			o->dpy = get(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
			if (o->dpy != EGL_NO_DISPLAY && !eglInitialize(o->dpy, NULL, NULL)) o->dpy = EGL_NO_DISPLAY;
		}
	}
	if (o->dpy == EGL_NO_DISPLAY) {
		snprintf(err, len, "no EGL display");
		if (o->wl) wl_display_disconnect(o->wl);
		return -1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	const EGLint attrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
	EGLConfig cfg = EGL_NO_CONFIG_KHR;
	EGLint n = 0;
	const EGLint cattrs[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_NONE };
	if (!eglChooseConfig(o->dpy, attrs, &cfg, 1, &n) || n < 1) cfg = EGL_NO_CONFIG_KHR;
	o->ctx = eglCreateContext(o->dpy, cfg, EGL_NO_CONTEXT, cattrs);
	if (o->ctx == EGL_NO_CONTEXT || !eglMakeCurrent(o->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, o->ctx)) {
		snprintf(err, len, "no GLES 3 context");
		eglTerminate(o->dpy);
		if (o->wl) wl_display_disconnect(o->wl);
		return -1;
	}
	return 0;
}

static void offscreen_down(struct offscreen *o) {
	eglMakeCurrent(o->dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(o->dpy, o->ctx);
	eglTerminate(o->dpy);
	eglReleaseThread();
	if (o->wl) wl_display_disconnect(o->wl);
}

int wr_check_shader(const char *src, char *err, int len) {
	err[0] = 0;
	struct offscreen os;
	if (offscreen_up(&os, err, len) != 0) return -1;
	GLuint sh = glCreateShader(GL_FRAGMENT_SHADER);
	const char *srcs[2] = { trans_head, src };
	glShaderSource(sh, 2, srcs, NULL);
	glCompileShader(sh);
	GLint ok = 0;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	if (!ok) glGetShaderInfoLog(sh, len, NULL, err);
	glDeleteShader(sh);
	if (ok) {
		GLuint p = program(trans_head, src);
		if (!p) {
			snprintf(err, len, "link failed");
			ok = 0;
		} else {
			glDeleteProgram(p);
		}
	}
	offscreen_down(&os);
	return ok ? 0 : -1;
}

int wr_bench_video(const char *path, int frames, int hw, wr_video_bench *out) {
	memset(out, 0, sizeof *out);
	char err[256];
	struct offscreen os;
	if (offscreen_up(&os, err, sizeof err) != 0) return -1;
	int rc = -1;
	vdec *vd = vd_open(path, hw);
	if (vd) {
		vtex vt = { 0 };
		out->hw = vd_hw(vd);
		out->width = vd_width(vd);
		out->height = vd_height(vd);
		out->fps = vd_fps(vd);
		double t0 = now_s();
		struct AVFrame *f;
		double pts;
		while (out->frames < frames && vd_next(vd, &f, &pts) == 0) {
			if (vt_upload(&vt, os.dpy, f) != 0) break;
			out->frames++;
		}
		glFinish();
		out->seconds = now_s() - t0;
		out->zero_copy = vt.zero_copy;
		GLuint prog = program(vt.planes == 0 ? video_ext_src : video_frag_src, NULL);
		if (prog && out->frames > 0) {
			GLuint fbo, tex = texture(64, 36, NULL, 0);
			glGenFramebuffers(1, &fbo);
			glBindFramebuffer(GL_FRAMEBUFFER, fbo);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
			glViewport(0, 0, 64, 36);
			glUseProgram(prog);
			glUniform1f(glGetUniformLocation(prog, "flip"), 1.0f);
			glUniform2f(glGetUniformLocation(prog, "coff"), 0, 0);
			glUniform2f(glGetUniformLocation(prog, "cscl"), 1, 1);
			vt_bind(&vt, prog);
			glDrawArrays(GL_TRIANGLES, 0, 3);
			uint8_t px[64 * 36 * 4];
			glReadPixels(0, 0, 64, 36, GL_RGBA, GL_UNSIGNED_BYTE, px);
			double sum[3] = { 0 };
			for (int i = 0; i < 64 * 36; i++)
				for (int c = 0; c < 3; c++) sum[c] += px[i * 4 + c];
			for (int c = 0; c < 3; c++) out->mean[c] = sum[c] / (64 * 36);
			glDeleteFramebuffers(1, &fbo);
			glDeleteTextures(1, &tex);
			glDeleteProgram(prog);
		}
		vt_free(&vt, os.dpy);
		vd_close(vd);
		rc = out->frames > 0 ? 0 : -1;
	}
	offscreen_down(&os);
	return rc;
}

void wr_get_stats(wr_stats *out) {
	pthread_mutex_lock(&W.lock);
	*out = S;
	pthread_mutex_unlock(&W.lock);
	out->mode = V.mode;
	out->paused = V.paused;
	out->gl = W.ctxgl != EGL_NO_CONTEXT;
	out->position = V.mode == V_PLAY && !V.paused ? timeline(now_s()) : V.mode == V_PLAY ? V.T_pause : -1;
}
