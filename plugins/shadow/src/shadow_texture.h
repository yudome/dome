#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

struct ShadowBuildParams {
	float width = 0;
	float height = 0;
	float rounding = 0;
	float scale = 1;
	float range = 72;
	float offset = 0;
	float alpha = 0.55F;
	float contact = 0;
	bool cut_interior = false;
};

struct ShadowBuildResult {
	int width = 0;
	int height = 0;
	std::vector<unsigned char> pixels;
};

inline int shadowBoxRadius(float sigma) {
	if (sigma < 0.6F)
		return 0;

	return std::max(1, static_cast<int>(std::lround((std::sqrt(4.F * sigma * sigma + 1.F) - 1.F) / 2.F)));
}

inline void shadowBoxBlurH(const std::vector<float>& src, std::vector<float>& dst, int width, int height, int radius) {
	const float INV = 1.F / (2 * radius + 1);
	for (int y = 0; y < height; ++y) {
		const int ROW = y * width;
		float     sum = 0.F;
		for (int i = -radius; i <= radius; ++i) {
			if (i >= 0 && i < width)
				sum += src[ROW + i];
		}
		for (int x = 0; x < width; ++x) {
			dst[ROW + x] = sum * INV;
			const int ADD = x + radius + 1;
			const int SUB = x - radius;
			if (ADD < width)
				sum += src[ROW + ADD];
			if (SUB >= 0)
				sum -= src[ROW + SUB];
		}
	}
}

inline void shadowBoxBlurV(const std::vector<float>& src, std::vector<float>& dst, int width, int height, int radius) {
	const float INV = 1.F / (2 * radius + 1);
	for (int x = 0; x < width; ++x) {
		float sum = 0.F;
		for (int i = -radius; i <= radius; ++i) {
			if (i >= 0 && i < height)
				sum += src[i * width + x];
		}
		for (int y = 0; y < height; ++y) {
			dst[y * width + x] = sum * INV;
			const int ADD = y + radius + 1;
			const int SUB = y - radius;
			if (ADD < height)
				sum += src[ADD * width + x];
			if (SUB >= 0)
				sum -= src[SUB * width + x];
		}
	}
}

inline void shadowBlur(std::vector<float>& buffer, int width, int height, int radius) {
	if (radius <= 0)
		return;

	std::vector<float> tmp(buffer.size());
	for (int i = 0; i < 3; ++i) {
		shadowBoxBlurH(buffer, tmp, width, height, radius);
		shadowBoxBlurV(tmp, buffer, width, height, radius);
	}
}

inline void shadowTextureSize(float logicalWidth, float logicalHeight, float scale, int& width, int& height) {
	float texScale = 0.5F * scale;
	const float MAXDIM = 1024.F;
	if (std::max(logicalWidth, logicalHeight) * texScale > MAXDIM)
		texScale = MAXDIM / std::max(logicalWidth, logicalHeight);

	width = std::max(1, static_cast<int>(std::ceil(logicalWidth * texScale)));
	height = std::max(1, static_cast<int>(std::ceil(logicalHeight * texScale)));
}

inline ShadowBuildResult buildShadowTexture(const ShadowBuildParams& params) {
	ShadowBuildResult result;

	const float RANGE = std::clamp(params.range, 4.F, 120.F);
	const float OFFSET = std::clamp(params.offset, -32.F, 64.F);
	const float PAD = RANGE + std::abs(OFFSET) + 2.F;
	const float ALPHA = std::clamp(params.alpha, 0.F, 1.F);
	const float CONTACT = std::clamp(params.contact, 0.F, 1.F);
	const float WIDTH = params.width;
	const float HEIGHT = params.height;

	if (WIDTH < 1.F || HEIGHT < 1.F)
		return result;

	const float LOGICALW = WIDTH + 2.F * PAD;
	const float LOGICALH = HEIGHT + 2.F * PAD;

	shadowTextureSize(LOGICALW, LOGICALH, params.scale, result.width, result.height);

	const int TEXW = result.width;
	const int TEXH = result.height;
	const float RADIUS = std::clamp(params.rounding, 0.F, std::min(WIDTH, HEIGHT) * 0.5F);
	const float INNERW = WIDTH * 0.5F - RADIUS;
	const float INNERH = HEIGHT * 0.5F - RADIUS;
	const bool  CUT = params.cut_interior;

	const float STEPX = LOGICALW / TEXW;
	const float STEPY = LOGICALH / TEXH;
	const float AA = 1.F / std::min(STEPX, STEPY);
	const float AVGSCALE = 0.5F * (1.F / STEPX + 1.F / STEPY);

	const auto distance = [&](float px, float py) {
		const float QX = std::abs(px) - INNERW;
		const float QY = std::abs(py) - INNERH;
		const float OUTSIDE = std::hypot(std::max(QX, 0.F), std::max(QY, 0.F));
		return OUTSIDE + std::min(std::max(QX, QY), 0.F) - RADIUS;
	};

	const auto buildMask = [&](float offsetY) {
		std::vector<float> mask(static_cast<size_t>(TEXW) * TEXH);
		for (int y = 0; y < TEXH; ++y) {
			const float PY = (y + 0.5F) * STEPY - PAD - HEIGHT * 0.5F - offsetY;
			for (int x = 0; x < TEXW; ++x) {
				const float PX = (x + 0.5F) * STEPX - PAD - WIDTH * 0.5F;
				mask[static_cast<size_t>(y) * TEXW + x] = std::clamp(0.5F - distance(PX, PY) * AA, 0.F, 1.F);
			}
		}
		return mask;
	};

	std::vector<float> mainMask = buildMask(OFFSET);
	shadowBlur(mainMask, TEXW, TEXH, shadowBoxRadius((RANGE / 3.F) * AVGSCALE));

	std::vector<float> contactMask;
	if (CONTACT > 0.F) {
		contactMask = buildMask(0.F);
		shadowBlur(contactMask, TEXW, TEXH, shadowBoxRadius(2.F * AVGSCALE));
	}

	result.pixels.assign(static_cast<size_t>(TEXW) * TEXH * 4, 0);

	static constexpr int BAYER[4][4] = {
		{0, 8, 2, 10},
		{12, 4, 14, 6},
		{3, 11, 1, 9},
		{15, 7, 13, 5},
	};

	for (int y = 0; y < TEXH; ++y) {
		const float PY = (y + 0.5F) * STEPY - PAD - HEIGHT * 0.5F;
		for (int x = 0; x < TEXW; ++x) {
			const float PX = (x + 0.5F) * STEPX - PAD - WIDTH * 0.5F;
			if (CUT && distance(PX, PY) <= 0.F)
				continue;

			const size_t INDEX = static_cast<size_t>(y) * TEXW + x;
			const float  MAIN = ALPHA * mainMask[INDEX];
			const float  EDGE = CONTACT > 0.F ? CONTACT * contactMask[INDEX] : 0.F;
			float        a = 1.F - (1.F - MAIN) * (1.F - EDGE);
			if (a <= 0.F)
				continue;

			a += (BAYER[y & 3][x & 3] / 16.F - 0.5F) / 255.F;
			a = std::clamp(a, 0.F, 1.F);

			result.pixels[INDEX * 4 + 3] = static_cast<unsigned char>(std::lround(a * 255.F));
		}
	}

	return result;
}
