local repo = require("repo")
local guest = require("guest").guest

local shell = guest and "shell-guest.qml" or "shell.qml"

return {
    terminal       = "alacritty msg -s $XDG_RUNTIME_DIR/alacritty.sock create-window",
    -- terminal    = "footclient",
    fileManager    = "nautilus",
    browser        = "helium-browser",
    session        = "command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'",
    quickshell     = "sh -c 'ulimit -Sn 65536; export MALLOC_ARENA_MAX=2 MALLOC_TRIM_THRESHOLD_=65536 QSG_RENDER_LOOP=threaded QML_IMPORT_PATH=\"$HOME/.local/lib/yudae/qml:" .. repo .. "/shell/native/qml\"; exec quickshell -p " .. repo .. "/shell/" .. shell .. "'",
}
