hl.config({
    general = {
        gaps_in  = 4,
        gaps_out = 8,

        border_size = 2,

        col = {
            active_border   = "rgba(ffffffee)",
            inactive_border = "rgba(595959ff)",
        },

        resize_on_border = true,

        allow_tearing = false,

        layout = "dwindle",
    },

    animations = {
        enabled = true,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        disable_splash_rendering = true,
        background_color        = 0xff000000,
        allow_session_lock_restore = true,
    },

    render = {
        new_render_scheduling = true,
        cm_auto_hdr           = 0,
    },

    quirks = {
        skip_non_kms_dmabuf_formats = false,
    },

    ecosystem = {
        no_update_news   = true,
        no_donation_nag  = true,
    },
})
