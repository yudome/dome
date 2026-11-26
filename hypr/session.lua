local repo = require("repo")
local autostart = require("autostart")

local ok, prefs = pcall(dofile, repo .. "/shell/cache/settings.lua")
if not ok or type(prefs) ~= "table" then prefs = {} end

local function once(name, cmd)
  hl.exec_cmd("pgrep -x " .. name .. " >/dev/null || " .. cmd .. " &")
end

hl.on("hyprland.start", function ()
  hl.exec_cmd("sh -c 'systemctl --user import-environment DISPLAY WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP && systemctl --user restart yudaemond'")

  for _, app in ipairs(autostart) do once(app[1], app[2]) end

end)

if prefs.wallpaper then
  hl.exec_cmd("sh -lc '~/dotfiles/vm/desktop'")
end
