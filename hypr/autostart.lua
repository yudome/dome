local repo = require("repo")
local path = repo .. "/shell/cache/settings.lua"

local ok, prefs = pcall(dofile, path)
if not ok or type(prefs) ~= "table" then prefs = {} end

local vendor = io.open("/sys/class/dmi/id/sys_vendor")
local guest = vendor ~= nil and (vendor:read("l") or ""):find("QEMU") ~= nil
if vendor then vendor:close() end
local shell_entry = guest and "shell-guest.qml" or "shell.qml"

local function once(name, cmd)
  hl.exec_cmd("pgrep -x " .. name .. " >/dev/null || " .. cmd .. " &")
end

local autostart = {
  -- { "foot", "foot --server" },
  { "alacritty", "alacritty --daemon --socket $XDG_RUNTIME_DIR/alacritty.sock" },
  { "quickshell", "sh -c 'ulimit -Sn 65536; export MALLOC_ARENA_MAX=2 MALLOC_TRIM_THRESHOLD_=65536 QSG_RENDER_LOOP=threaded QML_IMPORT_PATH=\"$HOME/.local/lib/yudae/qml:" .. repo .. "/shell/native/qml\"; exec quickshell -p " .. repo .. "/shell/" .. shell_entry .. "'" },
  { "polkit-gnome-au", "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1" },
}

hl.on("hyprland.start", function ()
  hl.exec_cmd("sh -c 'systemctl --user import-environment DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP && systemctl --user restart yudaemond'")

  for _, app in ipairs(autostart) do once(app[1], app[2]) end

end)

if prefs.wallpaper then
  hl.exec_cmd("sh -lc '~/dotfiles/vm/desktop'")
end
