local repo = os.getenv("DOTFILES_REPO") or ((os.getenv("HOME") or "") .. "/dotfiles")
package.path = repo .. "/hypr/?.lua;" .. package.path

require("monitors")
require("envs")
require("input")

hl.config({
    general = {
        gaps_in     = 0,
        gaps_out    = 0,
        border_size = 0,
    },

    decoration = {
        shadow = { enabled = false },
        blur   = { enabled = false },
    },

    animations = {
        enabled = false,
    },

    misc = {
        force_default_wallpaper  = 0,
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        background_color         = 0xff000000,
    },
})

local log = (os.getenv("HOME") or "/tmp") .. "/greeter.log"
local shell = "QML_IMPORT_PATH=" .. repo .. "/shell/native/qml quickshell -p " .. repo .. "/shell/greeter.qml"

hl.on("hyprland.start", function ()
  hl.exec_cmd("sh -c '" .. shell .. " >" .. log .. " 2>&1; hyprctl dispatch \"hl.dsp.exit()\"'")
end)
