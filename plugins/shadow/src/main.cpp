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

#include "shadow_texture.h"

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

        const float WROUNDING = WINDOW->presentation().rounding();
        const float ROUNDING  = std::max(0.F, WROUNDING + WINDOW->presentation().borderSize());
        const bool  SQUARE    = WROUNDING <= 0.F;
        const bool  ANIMATING = WINDOW->sizeAnimation()->isBeingAnimated() || WINDOW->positionAnimation()->isBeingAnimated();

        if (!m_texture || !ANIMATING)
            ensureTexture(box.w, box.h, ROUNDING, monitor->m_scale, !SQUARE);
        if (!m_texture)
            return;

        const float PAD = currentPad();
        CBox        windowBox = box;
        windowBox.scale(monitor->m_scale).round();

        CBox texBox = box;
        texBox.addExtents(SBoxExtents{.topLeft = {PAD, PAD}, .bottomRight = {PAD, PAD}});
        texBox.scale(monitor->m_scale).round();

        CTexPassElement::SRenderData data;
        data.tex = m_texture;
        data.box = texBox;
        data.a   = alpha;

        if (SQUARE) {
            CRegion clip(texBox);
            clip.subtract(CRegion(windowBox));
            data.clipRegion = clip;
        }

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

    void ensureTexture(float width, float height, float rounding, float scale, bool cutInterior) {
        const float RANGE   = currentRange();
        const float OFFSET  = currentOffset();
        const float PAD     = currentPad();
        const float ALPHA   = std::clamp(g_alpha->value(), 0.F, 1.F);
        const float CONTACT = std::clamp(g_contact->value(), 0.F, 1.F);

        const float LOGICALW = width + 2.F * PAD;
        const float LOGICALH = height + 2.F * PAD;
        int         texW = 0;
        int         texH = 0;
        shadowTextureSize(LOGICALW, LOGICALH, scale, texW, texH);

        SCacheKey key{
            .width    = texW,
            .height   = texH,
            .boxW     = static_cast<int>(std::lround(width * 4.F)),
            .boxH     = static_cast<int>(std::lround(height * 4.F)),
            .rounding = static_cast<int>(std::lround(rounding * 4.F)),
            .range    = static_cast<int>(std::lround(RANGE * 16.F)),
            .offset   = static_cast<int>(std::lround(OFFSET * 16.F)),
            .alpha    = static_cast<int>(std::lround(ALPHA * 1000.F)),
            .contact  = static_cast<int>(std::lround(CONTACT * 1000.F)),
        };
        if (m_texture && key == m_key)
            return;

        ShadowBuildParams params;
        params.width = width;
        params.height = height;
        params.rounding = rounding;
        params.scale = scale;
        params.range = RANGE;
        params.offset = OFFSET;
        params.alpha = ALPHA;
        params.contact = CONTACT;
        params.cut_interior = cutInterior;

        ShadowBuildResult built = buildShadowTexture(params);
        if (built.width < 1 || built.height < 1)
            return;

        m_texture = g_pHyprRenderer->createTexture(built.width, built.height, built.pixels.data());
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
    g_contact = makeShared<Config::Values::CFloatValue>("plugin:shadow:contact", "Tight contact shadow strength", 0.F, Config::Values::SFloatValueOptions{.min = 0.F, .max = 1.F});

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
