#pragma once

#include <QColor>
#include <QQuickItem>
#include <QtQml/qqmlregistration.h>

class ShadowTexture : public QQuickItem {
	Q_OBJECT
	QML_ELEMENT
	Q_PROPERTY(qreal cardWidth READ cardWidth WRITE setCardWidth NOTIFY changed)
	Q_PROPERTY(qreal cardHeight READ cardHeight WRITE setCardHeight NOTIFY changed)
	Q_PROPERTY(qreal range READ range WRITE setRange NOTIFY changed)
	Q_PROPERTY(qreal offset READ offset WRITE setOffset NOTIFY changed)
	Q_PROPERTY(qreal alpha READ alpha WRITE setAlpha NOTIFY changed)
	Q_PROPERTY(qreal contact READ contact WRITE setContact NOTIFY changed)
	Q_PROPERTY(qreal radius READ radius WRITE setRadius NOTIFY changed)
	Q_PROPERTY(qreal textureScale READ textureScale WRITE setTextureScale NOTIFY changed)
	Q_PROPERTY(QColor tint READ tint WRITE setTint NOTIFY changed)

public:
	explicit ShadowTexture(QQuickItem *parent = nullptr);

	qreal cardWidth() const { return m_cardWidth; }
	qreal cardHeight() const { return m_cardHeight; }
	qreal range() const { return m_range; }
	qreal offset() const { return m_offset; }
	qreal alpha() const { return m_alpha; }
	qreal contact() const { return m_contact; }
	qreal radius() const { return m_radius; }
	qreal textureScale() const { return m_textureScale; }
	QColor tint() const { return m_tint; }

	void setCardWidth(qreal value);
	void setCardHeight(qreal value);
	void setRange(qreal value);
	void setOffset(qreal value);
	void setAlpha(qreal value);
	void setContact(qreal value);
	void setRadius(qreal value);
	void setTextureScale(qreal value);
	void setTint(const QColor &value);

signals:
	void changed();

protected:
	QSGNode *updatePaintNode(QSGNode *node, UpdatePaintNodeData *data) override;
	void geometryChange(const QRectF &next, const QRectF &prev) override;

private:
	void markDirty();

	qreal m_cardWidth = 0;
	qreal m_cardHeight = 0;
	qreal m_range = 72;
	qreal m_offset = 0;
	qreal m_alpha = 0.55;
	qreal m_contact = 0;
	qreal m_radius = 0;
	qreal m_textureScale = 1;
	QColor m_tint = QColor(0, 0, 0, 255);
	bool m_dirty = true;
};
