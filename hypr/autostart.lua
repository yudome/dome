local programs = require("programs")

return {
    -- { "foot", "foot --server" },
    { "alacritty", "alacritty --daemon --socket $XDG_RUNTIME_DIR/alacritty.sock" },
    { "quickshell", programs.quickshell },
    { "polkit-gnome-au", "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" },
}
