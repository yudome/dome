#define WLR_USE_UNSTABLE

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <numbers>
#include <vector>

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowPresentation.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>

#include <unordered_map>

inline HANDLE PHANDLE = nullptr;

static SP<Config::Values::CBoolValue>  g_enabled;
static SP<Config::Values::CFloatValue> g_range;
static SP<Config::Values::CFloatValue> g_offset;
static SP<Config::Values::CFloatValue> g_alpha;
static SP<Config::Values::CFloatValue> g_contact;


static float currentRange() {
    return std::clamp(g_range->value(), 4.F, 120.F);
}

static float currentOffset() {
    return std::clamp(g_offset->value(), -32.F, 64.F);
}

static float currentPad() {
    return currentRange() + std::abs(currentOffset()) + 2.F;
}

static bool shouldHaveShadow(PHLWINDOW window) {
    if (!g_enabled || !g_enabled->value() || !window || !validMapped(window))
        return false;

    if (Fullscreen::controller()->isFullscreen(window))
        return false;

    const auto& TRAITS = window->backend().traits();
    if (TRAITS.overrideRedirect || TRAITS.suggestsNoBorder)
        return false;

    return window->m_ruleApplicator->decorate().valueOrDefault() && !window->m_ruleApplicator->noShadow().valueOrDefault();
}

static void damageAround(PHLWINDOW window) {
    if (!window || !validMapped(window))
        return;

    CBox box = g_pDecorationPositioner->getBoxWithIncludedDecos(window);
    const float PAD = currentPad();
    box.addExtents(SBoxExtents{.topLeft = {PAD, PAD}, .bottomRight = {PAD, PAD}});
    box.translate(window->presentation().floatingOffset());

    g_pHyprRenderer->damageRegion(CRegion(box));
}

class CSoftShadowDecoration : public IHyprWindowDecoration {
  public:
    CSoftShadowDecoration(PHLWINDOW window) : IHyprWindowDecoration(window), m_window(window) {
        ;
    }

    SDecorationPositioningInfo getPositioningInfo() override {
        const auto  WINDOW = m_window.lock();
        const float PAD    = shouldHaveShadow(WINDOW) ? currentPad() : 0.F;

        SDecorationPositioningInfo info;
        info.policy         = DECORATION_POSITION_ABSOLUTE;
        info.edges          = DECORATION_EDGE_BOTTOM | DECORATION_EDGE_LEFT | DECORATION_EDGE_RIGHT | DECORATION_EDGE_TOP;
        info.desiredExtents = {.topLeft = {PAD, PAD}, .bottomRight = {PAD, PAD}};
        return info;
    }

    void onPositioningReply(const SDecorationPositioningReply& reply) override {
        ;
    }

    void draw(Render::CRenderContext& ctx, PHLMONITOR monitor, float const& alpha, const Render::SWindowRenderPresentation& presentation) override {
        const auto WINDOW = m_window.lock();
        if (!shouldHaveShadow(WINDOW))
            return;

        if (Fullscreen::controller()->hasFullscreen(monitor))
            return;

        CBox box = g_pDecorationPositioner->getBoxWithIncludedDecos(WINDOW);
        box.translate(presentation.workspaceOffset - monitor->m_position);
        box.translate(presentation.floatingOffset);
        if (box.w < 1 || box.h < 1)
            return;

        const float ROUNDING  = std::max(0.F, WINDOW->presentation().rounding() + WINDOW->presentation().borderSize());
        const bool  ANIMATING = WINDOW->sizeAnimation()->isBeingAnimated() || WINDOW->positionAnimation()->isBeingAnimated();

        if (!m_texture || !ANIMATING)
            ensureTexture(box.w, box.h, ROUNDING, monitor->m_scale);
        if (!m_texture)
            return;

        const float PAD = currentPad();
        CBox        texBox = box;
        texBox.addExtents(SBoxExtents{.topLeft = {PAD, PAD}, .bottomRight = {PAD, PAD}});
        texBox.scale(monitor->m_scale).round();

        CTexPassElement::SRenderData data;
        data.tex = m_texture;
        data.box = texBox;
        data.a   = alpha;

        g_pHyprRenderer->addPassElement(ctx, makeUnique<CTexPassElement>(data));
    }

    eDecorationType getDecorationType() override {
        return DECORATION_CUSTOM;
    }

    void updateWindow(PHLWINDOW window) override {
        ;
    }

    void damageEntire() override {
        damageAround(m_window.lock());
    }

    void refreshPositioning() {
        damageAround(m_window.lock());
        g_pDecorationPositioner->repositionDeco(this);
    }

    eDecorationLayer getDecorationLayer() override {
        return DECORATION_LAYER_BOTTOM;
    }

    uint64_t getDecorationFlags() override {
        return DECORATION_NON_SOLID;
    }

    std::string getDisplayName() override {
        return "Shadow";
    }

  private:
    struct SCacheKey {
        int   width = 0, height = 0;
        int   boxW = 0, boxH = 0, rounding = 0;
        int   range = 0, offset = 0, alpha = 0, contact = 0;

        bool operator==(const SCacheKey&) const = default;
    };

    PHLWINDOWREF         m_window;
    SP<Render::ITexture> m_texture;
    SCacheKey            m_key;

    static void boxBlurH(const std::vector<float>& src, std::vector<float>& dst, int width, int height, int radius) {
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

    static void boxBlurV(const std::vector<float>& src, std::vector<float>& dst, int width, int height, int radius) {
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

    static void blur(std::vector<float>& buffer, int width, int height, int radius) {
        if (radius <= 0)
            return;

        std::vector<float> tmp(buffer.size());
        for (int i = 0; i < 3; ++i) {
            boxBlurH(buffer, tmp, width, height, radius);
            boxBlurV(tmp, buffer, width, height, radius);
        }
    }

    static int boxRadius(float sigma) {
        if (sigma < 0.6F)
            return 0;
        return std::max(1, static_cast<int>(std::lround((std::sqrt(4.F * sigma * sigma + 1.F) - 1.F) / 2.F)));
    }

    void ensureTexture(float width, float height, float rounding, float scale) {
        const float RANGE   = currentRange();
        const float OFFSET  = currentOffset();
        const float PAD     = currentPad();
        const float ALPHA   = std::clamp(g_alpha->value(), 0.F, 1.F);
        const float CONTACT = std::clamp(g_contact->value(), 0.F, 1.F);

        const float GENW = std::max(32.F, std::round(width / 32.F) * 32.F);
        const float GENH = std::max(32.F, std::round(height / 32.F) * 32.F);
        const float LOGICALW = GENW + 2.F * PAD;
        const float LOGICALH = GENH + 2.F * PAD;

        float texScale = 0.5F * scale;
        const float MAXDIM = 1024.F;
        if (std::max(LOGICALW, LOGICALH) * texScale > MAXDIM)
            texScale = MAXDIM / std::max(LOGICALW, LOGICALH);

        const int TEXW = std::max(1, static_cast<int>(std::ceil(LOGICALW * texScale)));
        const int TEXH = std::max(1, static_cast<int>(std::ceil(LOGICALH * texScale)));

        SCacheKey key{
            .width    = TEXW,
            .height   = TEXH,
            .boxW     = static_cast<int>(GENW),
            .boxH     = static_cast<int>(GENH),
            .rounding = static_cast<int>(std::lround(rounding * 4.F)),
            .range    = static_cast<int>(std::lround(RANGE * 16.F)),
            .offset   = static_cast<int>(std::lround(OFFSET * 16.F)),
            .alpha    = static_cast<int>(std::lround(ALPHA * 1000.F)),
            .contact  = static_cast<int>(std::lround(CONTACT * 1000.F)),
        };
        if (m_texture && key == m_key)
            return;

        const float RADIUS = std::clamp(rounding, 0.F, std::min(GENW, GENH) * 0.5F);
        const float INNERW = GENW * 0.5F - RADIUS;
        const float INNERH = GENH * 0.5F - RADIUS;

        const float STEPX      = LOGICALW / TEXW;
        const float STEPY      = LOGICALH / TEXH;
        const float AA        = 1.F / std::min(STEPX, STEPY);
        const float AVGSCALE  = 0.5F * (1.F / STEPX + 1.F / STEPY);

        const auto  distance = [&](float px, float py) {
            const float QX      = std::abs(px) - INNERW;
            const float QY      = std::abs(py) - INNERH;
            const float OUTSIDE = std::hypot(std::max(QX, 0.F), std::max(QY, 0.F));
            return OUTSIDE + std::min(std::max(QX, QY), 0.F) - RADIUS;
        };

        const auto buildMask = [&](float offsetY) {
            std::vector<float> mask(static_cast<size_t>(TEXW) * TEXH);
            for (int y = 0; y < TEXH; ++y) {
                const float PY = (y + 0.5F) * STEPY - PAD - GENH * 0.5F - offsetY;
                for (int x = 0; x < TEXW; ++x) {
                    const float PX = (x + 0.5F) * STEPX - PAD - GENW * 0.5F;
                    mask[static_cast<size_t>(y) * TEXW + x] = std::clamp(0.5F - distance(PX, PY) * AA, 0.F, 1.F);
                }
            }
            return mask;
        };

        std::vector<float> mainMask    = buildMask(OFFSET);
        std::vector<float> contactMask = buildMask(0.F);

        blur(mainMask, TEXW, TEXH, boxRadius((RANGE / 3.F) * AVGSCALE));
        blur(contactMask, TEXW, TEXH, boxRadius(2.F * AVGSCALE));

        std::vector<unsigned char> pixels(static_cast<size_t>(TEXW) * TEXH * 4, 0);

        static constexpr int BAYER[4][4] = {
            {0, 8, 2, 10},
            {12, 4, 14, 6},
            {3, 11, 1, 9},
            {15, 7, 13, 5},
        };

        for (int y = 0; y < TEXH; ++y) {
            const float PY = (y + 0.5F) * STEPY - PAD - GENH * 0.5F;
            for (int x = 0; x < TEXW; ++x) {
                const float PX = (x + 0.5F) * STEPX - PAD - GENW * 0.5F;
                if (distance(PX, PY) <= 0.F)
                    continue;

                const size_t INDEX = static_cast<size_t>(y) * TEXW + x;
                const float  MAIN  = ALPHA * mainMask[INDEX];
                const float  EDGE  = CONTACT * contactMask[INDEX];
                float        a     = 1.F - (1.F - MAIN) * (1.F - EDGE);
                if (a <= 0.F)
                    continue;

                a += (BAYER[y & 3][x & 3] / 16.F - 0.5F) / 255.F;
                a = std::clamp(a, 0.F, 1.F);

                pixels[INDEX * 4 + 3] = static_cast<unsigned char>(std::lround(a * 255.F));
            }
        }

        m_texture = g_pHyprRenderer->createTexture(TEXW, TEXH, pixels.data());
        if (m_texture)
            m_key = key;
    }
};

static std::unordered_map<Desktop::View::CWindow*, SP<CSoftShadowDecoration>> g_decorations;

static void repositionFor(PHLWINDOW window) {
    if (!window)
        return;

    const auto IT = g_decorations.find(window.get());
    if (IT != g_decorations.end())
        IT->second->refreshPositioning();
}

static void addDecoration(PHLWINDOW window) {
    if (!window || !validMapped(window))
        return;

    if (g_decorations.contains(window.get()))
        return;

    auto decoration = makeShared<CSoftShadowDecoration>(window);
    auto keep       = decoration;
    if (!HyprlandAPI::addWindowDecoration(PHANDLE, window, std::move(decoration)))
        return;

    g_decorations[window.get()] = keep;
    keep->damageEntire();
}

static CHyprSignalListener g_openListener;
static CHyprSignalListener g_closeListener;
static CHyprSignalListener g_reloadListener;
static CHyprSignalListener g_rulesListener;
static CHyprSignalListener g_fsListener;
static CHyprSignalListener g_floatingListener;

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();
    if (HASH != CLIENT_HASH)
        throw std::runtime_error("[shadow] Version mismatch between headers and running Hyprland");

    g_enabled = makeShared<Config::Values::CBoolValue>("plugin:shadow:enabled", "Enable window shadows", true);
    g_range   = makeShared<Config::Values::CFloatValue>("plugin:shadow:range", "Visible shadow falloff in logical pixels", 72.F, Config::Values::SFloatValueOptions{.min = 4.F, .max = 120.F});
    g_offset  = makeShared<Config::Values::CFloatValue>("plugin:shadow:offset", "Downward shadow shift in logical pixels", 0.F, Config::Values::SFloatValueOptions{.min = -32.F, .max = 64.F});
    g_alpha   = makeShared<Config::Values::CFloatValue>("plugin:shadow:alpha", "Main shadow strength", 0.55F, Config::Values::SFloatValueOptions{.min = 0.F, .max = 1.F});
    g_contact = makeShared<Config::Values::CFloatValue>("plugin:shadow:contact", "Tight contact shadow strength", 0.12F, Config::Values::SFloatValueOptions{.min = 0.F, .max = 1.F});

    HyprlandAPI::addConfigValueV2(PHANDLE, g_enabled);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_range);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_offset);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_alpha);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_contact);
    HyprlandAPI::reloadConfig();

    g_openListener     = Event::bus()->m_events.window.open.listen([](PHLWINDOW window) { addDecoration(window); });
    g_closeListener    = Event::bus()->m_events.window.close.listen([](PHLWINDOW window) { g_decorations.erase(window.get()); });
    g_rulesListener    = Event::bus()->m_events.window.updateRules.listen([](PHLWINDOW window) { repositionFor(window); });
    g_fsListener       = Event::bus()->m_events.window.fullscreen.listen([](PHLWINDOW window) { repositionFor(window); });
    g_floatingListener = Event::bus()->m_events.window.floating.listen([](PHLWINDOW window) { repositionFor(window); });
    g_reloadListener   = Event::bus()->m_events.config.reloaded.listen([]() {
        for (const auto& [window, decoration] : g_decorations)
            decoration->refreshPositioning();
    });

    for (const auto& WINDOW : Desktop::windowState()->windows())
        addDecoration(WINDOW);

    return {"shadow", "General soft window shadows", "yudae", "1.0.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    for (const auto& [window, decoration] : g_decorations)
        HyprlandAPI::removeWindowDecoration(PHANDLE, decoration.get());
    g_decorations.clear();
}
