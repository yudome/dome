#include "shadowtexture.h"

#include <QImage>
#include <QQuickWindow>
#include <QSGSimpleTextureNode>
#include <QSGTexture>

#include "shadow_texture.h"

namespace {

class ShadowTextureNode : public QSGSimpleTextureNode {
public:
	~ShadowTextureNode() override { delete texture(); }

	void swap(QSGTexture *next) {
		QSGTexture *old = texture();
		setTexture(next);
		delete old;
	}
};

}

ShadowTexture::ShadowTexture(QQuickItem *parent) : QQuickItem(parent) {
	setFlag(ItemHasContents, true);
}

void ShadowTexture::setCardWidth(qreal value) {
	if (qFuzzyCompare(m_cardWidth, value))
		return;

	m_cardWidth = value;
	markDirty();
}

void ShadowTexture::setCardHeight(qreal value) {
	if (qFuzzyCompare(m_cardHeight, value))
		return;

	m_cardHeight = value;
	markDirty();
}

void ShadowTexture::setRange(qreal value) {
	if (qFuzzyCompare(m_range, value))
		return;

	m_range = value;
	markDirty();
}

void ShadowTexture::setOffset(qreal value) {
	if (qFuzzyCompare(m_offset, value))
		return;

	m_offset = value;
	markDirty();
}

void ShadowTexture::setAlpha(qreal value) {
	if (qFuzzyCompare(m_alpha, value))
		return;

	m_alpha = value;
	markDirty();
}

void ShadowTexture::setContact(qreal value) {
	if (qFuzzyCompare(m_contact, value))
		return;

	m_contact = value;
	markDirty();
}

void ShadowTexture::setRadius(qreal value) {
	if (qFuzzyCompare(m_radius, value))
		return;

	m_radius = value;
	markDirty();
}

void ShadowTexture::setTextureScale(qreal value) {
	if (qFuzzyCompare(m_textureScale, value))
		return;

	m_textureScale = value;
	markDirty();
}

void ShadowTexture::setTint(const QColor &value) {
	if (m_tint == value)
		return;

	m_tint = value;
	markDirty();
}

void ShadowTexture::markDirty() {
	m_dirty = true;
	update();
	emit changed();
}

void ShadowTexture::geometryChange(const QRectF &next, const QRectF &prev) {
	QQuickItem::geometryChange(next, prev);

	if (next.size() != prev.size())
		markDirty();
}

QSGNode *ShadowTexture::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
	auto *node = static_cast<ShadowTextureNode *>(old);

	if (node != nullptr && !m_dirty)
		return node;

	ShadowBuildParams params;
	params.width = m_cardWidth;
	params.height = m_cardHeight;
	params.rounding = m_radius;
	params.scale = m_textureScale > 0 ? m_textureScale : 1;
	params.range = m_range;
	params.offset = m_offset;
	params.alpha = m_alpha;
	params.contact = m_contact;
	params.cut_interior = true;

	const ShadowBuildResult built = buildShadowTexture(params);

	if (built.width < 1 || built.height < 1) {
		delete node;
		m_dirty = false;
		return nullptr;
	}

	const QColor color = m_tint.isValid() ? m_tint : QColor(0, 0, 0, 255);
	QImage image(built.width, built.height, QImage::Format_RGBA8888_Premultiplied);

	for (int y = 0; y < built.height; ++y) {
		uchar *row = image.scanLine(y);
		const size_t at = static_cast<size_t>(y) * built.width * 4;

		for (int x = 0; x < built.width; ++x) {
			const size_t index = at + static_cast<size_t>(x) * 4;
			const int a = built.pixels[index + 3];

			row[x * 4 + 0] = static_cast<uchar>((color.red() * a + 127) / 255);
			row[x * 4 + 1] = static_cast<uchar>((color.green() * a + 127) / 255);
			row[x * 4 + 2] = static_cast<uchar>((color.blue() * a + 127) / 255);
			row[x * 4 + 3] = static_cast<uchar>(a);
		}
	}

	if (node == nullptr) {
		node = new ShadowTextureNode;
		node->setFiltering(QSGTexture::Linear);
	}

	node->swap(window()->createTextureFromImage(image, QQuickWindow::TextureHasAlphaChannel));
	node->setRect(boundingRect());
	m_dirty = false;

	return node;
}
